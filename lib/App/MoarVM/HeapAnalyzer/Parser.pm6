use v6.d;

unit class App::MoarVM::HeapAnalyzer::Parser is export;

#use App::MoarVM::HeapAnalyzer::LogTimelineSchema;
#use Compress::Zstd;

class TocEntry {
    has Str $.kind;
    has Int $.position;
    has Int $.end;

    method new-from(blob8 $blob) {
        my $kind = no-nulls($blob.subbuf(0, 8).decode("utf8"));
        my $position = $blob.read-uint64(8);
        my $end = $blob.read-uint64(16);
        self.bless(:$kind, :$position, :$end);
    }

    method gist {
        " $.kind.fmt("%-9s") [$.position.fmt("%8x") - $.end.fmt("%8x") ($.length.fmt("%7x"))]"
    }
    method length( --> Int) {
        $.end - $.position
    }
}

has &.fh-factory;
has @!snapshot-tocs;

has @!stringheap;

method new($path) {
    self.bless(fh-factory =>
            -> $pos = 0 {
                my $fh = $path.IO.open(:r, :bin);
                $fh.seek($pos, SeekFromEnd) if $pos < 0;
                $fh.seek($pos, SeekFromBeginning) if $pos > 0;
                $fh
            });
}

sub no-nulls($str is copy) {
    if $str ~~ Blob {
        $str = $str.decode("utf8")
    }
    $str .= chop while $str.ends-with("\0");
    $str
}

method read-toc-contents(blob8 $toc) {
    do while $toc.elems > 8 {
        NEXT { $toc .= subbuf(24, *) }
        TocEntry.new-from($toc);
    }
}

method read-string-heap() {
    @!stringheap
}

method read-staticframes() {
    my %interesting-kinds is Set = "sfname", "sfcuid", "sfline", "sffile";
    my %tocs-per-kind;
    for @!snapshot-tocs.map({ $^toc with $^toc.first({ .kind ~~ %interesting-kinds.keys.any }) }) {
        my @tocs = .grep({ .kind ~~ %interesting-kinds.keys.any });

        %tocs-per-kind{.kind}.push($_) for @tocs;
    }

    my %results = :sfname, :sfcuid, :sfline, :sffile;

    await do for %interesting-kinds.keys -> $kindname {
        start {
            my @values;
            if $kindname eq "sfline" { @values := my int32 @ }
            else { @values := my int @ }

            for %tocs-per-kind{$kindname}.pairs -> $p {
                self!read-attribute-stream($kindname, $p.value, :@values, :input-buffer, :output-buffer);
            }

            %results{$kindname} := @values;
            CATCH { note "$kindname exception: $_" }
        }
    }

    %results;
}

method read-types() {
    my %interesting-kinds is Set = "reprname", "typename";
    my %tocs-per-kind;
    for @!snapshot-tocs.map({ $^toc with $^toc.first({ .kind ~~ %interesting-kinds.keys.any }) }) {
        my @tocs = .grep({ .kind ~~ %interesting-kinds.keys.any });

        %tocs-per-kind{.kind}.push($_) for @tocs;
    }

    my %results = :reprname, :typename;

    await do for %interesting-kinds.keys -> $kindname {
        #note "asking for a token for $kindname" with $*TOKEN-POOL;
        start {
            my int @values;
            for %tocs-per-kind{$kindname}.pairs -> $p {
                self!read-attribute-stream($kindname, $p.value, :@values
                    :input-buffer, :output-buffer
                );
            };
            %results{$kindname} := @values;
            CATCH { note "$kindname exception: $_" }
        }
    }

    %results;
}


method !read-attribute-stream($kindname, $toc, :$values is copy, :$if = &.fh-factory.(), :$input-buffer, :$output-buffer) {
    #App::MoarVM::HeapAnalyzer::Log::ParseAttributeStream.log: kind => $kindname, position => $toc.position.fmt("%x"), {
        my $realstart = now;
        my \if := $if;
        if.seek($toc.position);

        die "that's not the kind i'm looking for?!" unless if.read(8).&no-nulls eq $kindname;

        my $entrysize = if.read(2).read-uint16(0);
        my $size = if.read(8).read-uint64(0);

        without $values {
            if $entrysize == 2 {
                $values = my uint16 @;
            }
            elsif $entrysize == 4 {
                $values = my uint32 @;
            }
            elsif $entrysize == 8 {
                $values = my uint64 @;
            }
            else {
                note "what $entrysize $kindname";
            }
        }

        $values<>;
    #}
}

method fetch-collectable-data(
        :$toc, :$index,

        :@col-kinds!, :@col-desc-indexes!, :@col-size!, :@col-unmanaged-size!,
        :@col-refs-start!, :@col-num-refs!,

        :$num-objects! is rw,
        :$num-type-objects! is rw,
        :$num-stables! is rw,
        :$num-frames! is rw,
        :$total-size! is rw,

        :$progress
        ) {

    my %kinds-to-arrays = %(
            colkind => @col-kinds,
            colsize => @col-size,
            coltofi => @col-desc-indexes,
            colrfcnt => @col-num-refs,
            colrfstr => @col-refs-start,
            colusize => @col-unmanaged-size
            );

    my @interesting = $toc.grep(*.kind eq %kinds-to-arrays.keys.any);

    my Promise $kinds-promise .= new;
    my Promise $colsize-promise .= new;
    my Promise $colusize-promise .= new;

    my int64 $stat-total-size;
    my int64 $stat-total-usize;

    note "add 1 target for kind-stats-promise";
    .add-target(1) with $progress;
    my $kind-stats-done = $kinds-promise.then({
        .increment with $progress;
    });

    note "add 2 targets for colsize stats and colusize stats";
    .add-target(2) with $progress;
    my $colsize-stats-done = $colsize-promise.then({
        .increment with $progress;
    });

    my $colusize-stats-done = $colusize-promise.then({
        .increment with $progress;
    });

    await do for @interesting.list.sort(-*.length) {
        .increment-target with $progress;
        start {
            my $kindname = $_.kind;
            my $values := %kinds-to-arrays{.kind};
            self!read-attribute-stream(
                    .kind, $_, :$values
                    );
            if    .kind eq "colkind" { $kinds-promise.keep($values) }
            elsif .kind eq "colsize" { $colsize-promise.keep($values) }
            elsif .kind eq "colusize" { $colusize-promise.keep($values) }
            .increment with $progress;
            CATCH { note "$kindname exception: $_" }
        }
    }

    await $kind-stats-done, $colsize-stats-done, $colusize-stats-done;

    $total-size = $stat-total-size + $stat-total-usize;

    Nil
}

method fetch-references-data(
        :$toc, :$index,

        :@ref-kinds, :@ref-indexes, :@ref-tos,

        :$progress
        ) {
    my @interesting = $toc.grep(*.kind eq "refdescr" | "reftrget");

    await
        start {
            note "increment target for refdescr";
            .increment-target with $progress;
            my $thetoc = @interesting.first(*.kind eq "refdescr");
            my $kindname = "refdescr";
            my $data = self!read-attribute-stream("refdescr", $thetoc);
            .increment with $progress;
            CATCH { note "$kindname exception: $_" }
        },
        start {
            note "increment target for reftrget";
            .increment-target with $progress;
            my $thetoc = @interesting.first(*.kind eq "reftrget");
            my $kindname = "reftrget";

            self!read-attribute-stream("reftrget", $thetoc, values => @ref-tos);
            .increment with $progress;
            CATCH { note "$kindname exception: $_" }
        };
}


method find-outer-toc {
    my \if = &.fh-factory.();

    # First, find the starting position of the outermost TOC.
    # Its position lives in the last 8 bytes of the file, hopefully.
    if.seek(-8, SeekFromEnd);
    if.seek(if.read(8).read-uint64(0), SeekFromBeginning);

    die "expected last 8 bytes of file to lead to a toc. alas..." unless no-nulls(if.read(8)) eq "toc";

    #App::MoarVM::HeapAnalyzer::Log::ParseTOCs.log: {
        my $entries-to-read = if.read(8).read-uint64(0);
        my $toc = if.read($entries-to-read * 3 * 8);

        my @snapshot-tocs = self.read-toc-contents($toc);

        for @snapshot-tocs.head(*-1) {
            if.seek(.position);
            die "expected to find a toc here..." unless no-nulls(if.read(8)) eq "toc";
            #App::MoarVM::HeapAnalyzer::Log::ParseTOCFound.log();
            my $size = if.read(8);
            my $innertoc = if.read(.end - .position - 16);
            my @inner-toc-entries = self.read-toc-contents($innertoc);

            @!snapshot-tocs.push(@inner-toc-entries);
        }
    #}

    my $strings-promise = start 
    #App::MoarVM::HeapAnalyzer::Log::ParseStrings.log:
    {
        self.read-string-heap;
    }
    my $static-frames-promise = start
    #App::MoarVM::HeapAnalyzer::Log::ParseStaticFrames.log:
    {
        self.read-staticframes;
    }
    my $types-promise = start
    #App::MoarVM::HeapAnalyzer::Log::ParseTypes.log:
    {
        self.read-types;
    }

    return %(
            :$strings-promise,
            :$static-frames-promise,
            :$types-promise,
            snapshots => @!snapshot-tocs,
        );

    LEAVE { if.close }
}

