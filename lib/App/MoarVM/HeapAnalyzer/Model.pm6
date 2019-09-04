use v6.d;

unit class App::MoarVM::HeapAnalyzer::Model;

use Concurrent::Progress;

use nqp;

# We resolve the top-level data structures asynchronously.
has $!strings-promise;
has $!types-promise;
has $!static-frames-promise;

# Raw, unparsed, snapshot data.
has @!unparsed-snapshots;

# Promises that resolve to parsed snapshots.
has @!snapshot-promises;

has int $!version;

class Snapshot { ... }

# Holds and provides access to the types data set.
my class Types {
    has int @!repr-name-indexes;
    has int @!type-name-indexes;
    has @!strings;

    submethod BUILD(:@repr-name-indexes, int :@type-name-indexes, :@strings) {
        @!repr-name-indexes := @repr-name-indexes;
        @!type-name-indexes := @type-name-indexes;
        @!strings := @strings;
    }

    method repr-name(int $idx) {
        @!strings[@!repr-name-indexes[$idx]]
    }

    method type-name(int $idx) {
        @!strings[@!type-name-indexes[$idx]]
    }

    method all-with-type($name) {
        my int @found;
        with @!strings.first($name, :k) -> int $goal {
            my int $num-types = @!type-name-indexes.elems;
            loop (my int $i = 0; $i < $num-types; $i++) {
                @found.push($i) if @!type-name-indexes[$i] == $goal;
            }
        }
        @found
    }

    method all-with-repr($name) {
        my int @found;
        with @!strings.first($name, :k) -> int $goal {
            my int $num-types = @!repr-name-indexes.elems;
            loop (my int $i = 0; $i < $num-types; $i++) {
                @found.push($i) if @!repr-name-indexes[$i] == $goal;
            }
        }
        @found
    }
}

# Holds and provides access to the static frames data set.
my class StaticFrames {
    has int @!name-indexes;
    has int @!cuid-indexes;
    has int32 @!lines;
    has int @!file-indexes;
    has @!strings;

    submethod BUILD(:@name-indexes, :@cuid-indexes, :@lines, :@file-indexes, :@strings) {
        @!name-indexes := @name-indexes;
        @!cuid-indexes := @cuid-indexes;
        @!lines := @lines;
        @!file-indexes := @file-indexes;
        @!strings := @strings;
    }

    method summary(int $index) {
        my $name = @!strings[@!name-indexes[$index]] || '<anon>';
        my $line = @!lines[$index];
        my $path = @!strings[@!file-indexes[$index]];
        my $file = $path.split(/<[\\/]>/).tail;
        "$name ($file:$line)"
    }

    method all-with-name($name) {
        my int @found;
        with @!strings.first($name, :k) -> int $goal {
            my int $num-sf = @!name-indexes.elems;
            loop (my int $i = 0; $i < $num-sf; $i++) {
                @found.push($i) if @!name-indexes[$i] == $goal;
            }
        }
        if $name eq "<anon>" {
            my @more = self.all-with-name("");
            @found.splice(+@found, 0, @more);
        }
        @found
    }
}

# The various kinds of collectable.
my enum CollectableKind is export <<
    :Object(1) TypeObject STable Frame PermRoots InstanceRoots
    CStackRoots ThreadRoots Root InterGenerationalRoots CallStackRoots
>>;

my enum RefKind is export << :Unknown(0) Index String >>;

# Holds data about a snapshot and provides various query operations on it.
my class Snapshot {
    has int8 @!col-kinds;
    has int32 @!col-desc-indexes;
    has int16 @!col-size;
    has int32 @!col-unmanaged-size;
    has int32 @!col-refs-start;
    has int32 @!col-num-refs;

    has int @!col-revrefs-start;
    has int @!col-num-revrefs;

    has @!strings;
    has $!types;
    has $!static-frames;

    has $.num-objects;
    has $.num-type-objects;
    has $.num-stables;
    has $.num-frames;
    has $.total-size;

    has int8 @!ref-kinds;
    has int32 @!ref-indexes;
    has int32 @!ref-tos;

    has int @!revrefs-tos;

    has @!bfs-distances;
    has @!bfs-preds;
    has @!bfs-pred-refs;

    submethod BUILD(
        :@col-kinds, :@col-desc-indexes, :@col-size, :@col-unmanaged-size,
        :@col-refs-start, :@col-num-refs, :@strings, :$!types, :$!static-frames,
        :$!num-objects, :$!num-type-objects, :$!num-stables, :$!num-frames,
        :$!total-size, :@ref-kinds, :@ref-indexes, :@ref-tos
    ) {
        @!col-kinds := @col-kinds;
        @!col-desc-indexes := @col-desc-indexes;
        @!col-size := @col-size;
        @!col-unmanaged-size := @col-unmanaged-size;
        @!col-refs-start := @col-refs-start;
        @!col-num-refs := @col-num-refs;
        @!strings := @strings;
        @!ref-kinds := @ref-kinds;
        @!ref-indexes := @ref-indexes;
        @!ref-tos := @ref-tos;

        my $size = 0;
        for @!col-kinds, @!col-desc-indexes, @!col-size,
            @!col-unmanaged-size, @!col-refs-start, @!col-num-refs,
            @!strings, @!ref-kinds, @!ref-indexes, @!ref-tos {
            try $size += (($_.of.^nativesize // 64) div 8) * $_.elems()
        }
    }

    method forget() {
        @!col-kinds := my int8 @;
        @!col-desc-indexes = my int32 @;
        @!col-size = my int16 @;
        @!col-unmanaged-size = my int32 @;
        @!col-refs-start = my int32 @;
        @!col-num-refs = my int16 @;
        @!ref-kinds = my int8 @;
        @!ref-indexes = my int32 @;
        @!ref-tos = my int32 @;

        @!bfs-distances = my int @;
        @!bfs-preds = my int @;
        @!bfs-pred-refs = my int @;
    }

    method num-references() {
        @!ref-kinds.elems
    }
}

my int8 @empty-buf;
sub readSizedInt64(@buf) {
    #my $bytesize = 8;
    #my @buf := $fh.gimme(8);
    #die "expected $bytesize bytes, but got { @buf.elems() }" unless @buf.elems >= $bytesize;

    #my int64 $result = @buf.read-int64(0);
    #my int64 $result = nqp::readint(@buf,0,
          #BEGIN nqp::bitor_i(nqp::const::BINARY_SIZE_64_BIT,NativeEndian));


    my int64 $result =
            nqp::add_i nqp::shift_i(@buf),
            nqp::add_i nqp::bitshiftl_i(nqp::shift_i(@buf),  8),
            nqp::add_i nqp::bitshiftl_i(nqp::shift_i(@buf), 16),
            nqp::add_i nqp::bitshiftl_i(nqp::shift_i(@buf), 24),
            nqp::add_i nqp::bitshiftl_i(nqp::shift_i(@buf), 32),
            nqp::add_i nqp::bitshiftl_i(nqp::shift_i(@buf), 40),
            nqp::add_i nqp::bitshiftl_i(nqp::shift_i(@buf), 48),
                       nqp::bitshiftl_i(nqp::shift_i(@buf), 56);
    #@buf.splice(0, 8);
    #nqp::splice(@buf, @empty-buf, 0, 8);
    $result;
}
sub readSizedInt32(@buf) {
    #my $bytesize = 4;
    #my @buf := $fh.gimme(4);
    #die "expected $bytesize bytes, but got { @buf.elems() }" unless @buf.elems >= $bytesize;

    #my int64 $result = nqp::readint(@buf,0,
            #BEGIN nqp::bitor_i(nqp::const::BINARY_SIZE_32_BIT,NativeEndian));

    my int64 $result =
            nqp::add_i nqp::shift_i(@buf),
            nqp::add_i nqp::bitshiftl_i(nqp::shift_i(@buf),  8),
            nqp::add_i nqp::bitshiftl_i(nqp::shift_i(@buf), 16),
                       nqp::bitshiftl_i(nqp::shift_i(@buf), 24);

    #nqp::splice(@buf, @empty-buf, 0, 4);
    $result;

}
sub readSizedInt16(@buf) {
    #my $bytesize = 2;
    #my @buf := $fh.gimme(2);
    #die "expected $bytesize bytes, but got { @buf.elems() }" unless @buf.elems >= $bytesize;

    my int64 $result =
            nqp::add_i(nqp::shift_i(@buf),
                       nqp::bitshiftl_i(nqp::shift_i(@buf), 8));

    #my int64 $result = nqp::readint(@buf,0,
            #BEGIN nqp::bitor_i(nqp::const::BINARY_SIZE_16_BIT,NativeEndian));
    #nqp::splice(@buf, @empty-buf, 0, 2);
    $result;

}

submethod BUILD(IO::Path :$file = die "Must construct model with a file") {
    # Pull data from the file.
    my %top-level;
    my @snapshots;
    my $cur-snapshot-hash;

    $!version = 3;

    use App::MoarVM::HeapAnalyzer::Parser;

    my App::MoarVM::HeapAnalyzer::Parser $parser .= new($file);

    my %results := $parser.find-outer-toc;

    $!strings-promise = %results<strings-promise>;
    $!static-frames-promise = %results<static-frames-promise>.then({ given .result {
        StaticFrames.new(name-indexes => .<sfname>,
                cuid-indexes => .<sfcuid>,
                lines => .<sfline>,
                file-indexes => .<sffile>,
                strings => await $!strings-promise);
    }});
    $!types-promise = %results<types-promise>.then({ given .result {
        Types.new(repr-name-indexes => .<reprname>,
                  type-name-indexes => .<typename>,
                  strings => await $!strings-promise)
    }});
    @!unparsed-snapshots = do for %results<snapshots>.list.pairs {
        #say "unparsed snapshot: $_.key(): $_.value.perl()";
        %(:$parser, toc => .value, index => .key)
    }
}

sub expect-header($fh, $name, $text = $name.substr(0, 4)) {
    my $result = $fh.exactly($text.chars).decode("latin1");
    die "expected the $name header at 0x{ ($fh.tell - $text.chars).base(16) }, but got $result.perl() instead." unless $result eq $text;
}

method !parse-strings-ver2($fh) {
    expect-header($fh, "strings", "strs");
    my $stringcount = readSizedInt64($fh.gimme(8));
    LEAVE { $fh.close }
    do for ^$stringcount {
        my $length = readSizedInt64($fh.gimme(8));
        if !$length { say "string index $_ is an empty string" }
        $length ?? $fh.exactly($length).decode("utf8")
                !! ""
    }
}
method !parse-types-ver2($fh) {
    expect-header($fh, "types");
    my ($typecount, $size-per-type) = readSizedInt64($fh.gimme(8)) xx 2;
    my int @repr-name-indexes;
    my int @type-name-indexes;
    for ^$typecount {
        my @buf := $fh.gimme(16);
        my int64 $repr-name-index = readSizedInt64(@buf);
        say "type index $_ has an empty repr name" if $repr-name-index == 6;
        my int64 $type-name-index = readSizedInt64(@buf);
        say "type index $_ has an empty type name (repr index $repr-name-index)" if $type-name-index == 6;
        @repr-name-indexes.push($repr-name-index);
        @type-name-indexes.push($type-name-index);
    }
    $fh.close;
    Types.new(:@repr-name-indexes, :@type-name-indexes, strings => await $!strings-promise);
}
method !parse-static-frames-ver2($fh) {
    expect-header($fh, "frames");
    my ($staticframecount, $size-per-frame) = readSizedInt64($fh.gimme(4)) xx 2;
    my int @name-indexes;
    my int @cuid-indexes;
    my int32 @lines;
    my int @file-indexes;
    for ^$staticframecount {
        my @buf := $fh.gimme(24);
        @name-indexes.push(readSizedInt64(@buf));
        @cuid-indexes.push(readSizedInt64(@buf));
        @lines       .push(readSizedInt64(@buf));
        @file-indexes.push(readSizedInt64(@buf));
    }
    $fh.close;
    StaticFrames.new(
        :@name-indexes, :@cuid-indexes, :@lines, :@file-indexes,
        strings => await $!strings-promise
    )
}


method !parse-types($types-str) {
    my int @repr-name-indexes;
    my int @type-name-indexes;
    for $types-str.split(';') {
        my @pieces := .split(',').List;
        @repr-name-indexes.push(@pieces[0].Int);
        @type-name-indexes.push(@pieces[1].Int);
    }
    Types.new(
        :@repr-name-indexes, :@type-name-indexes,
        strings => await $!strings-promise
    )
}

method !parse-static-frames($sf-str) {
    my int @name-indexes;
    my int @cuid-indexes;
    my int32 @lines;
    my int @file-indexes;
    for $sf-str.split(';') {
        my @pieces := .split(',').List;
        @name-indexes.push(@pieces[0].Int);
        @cuid-indexes.push(@pieces[1].Int);
        @lines.push(@pieces[2].Int);
        @file-indexes.push(@pieces[3].Int);
    }
    StaticFrames.new(
        :@name-indexes, :@cuid-indexes, :@lines, :@file-indexes,
        strings => await $!strings-promise
    )
}

method promise-snapshot($index, :$updates) {
    # XXX index checks
    die "no snapshot with index $index exists" unless @!unparsed-snapshots[$index]:exists;

    @!snapshot-promises[$index] //= start self!parse-snapshot(
        @!unparsed-snapshots[$index], :$updates
    )
}

method get-snapshot($index, :$updates) {
    # XXX index checks
    await self.promise-snapshot($index, :$updates);
}

method forget-snapshot($index) {
    my $promise = @!snapshot-promises[$index]:delete;
    with $promise {
        $promise.result.forget;
    }
    else {
        say "not sure why $index had no promise to forget ...";
    }
    CATCH {
        .say
    }
}

method !parse-snapshot($snapshot-task, :$updates) {
    my Concurrent::Progress $progress .= new(:1target, :!auto-done);

    LEAVE { note "leave parse-snapshot; increment"; .increment with $progress }

    start react whenever $progress {
        #$updates.emit:
            #%( snapshot_index => $snapshot-task<index>,
               #progress => [ .value, .target, .percent ]
           #);
       say "progress: $_.value.fmt("%3d") / $_.target.fmt("%3d") - $_.percent()%";
    }

    my $col-data = start {
        my int8 @col-kinds;
        my int32 @col-desc-indexes;
        my int16 @col-size;
        my int32 @col-unmanaged-size;
        my int32 @col-refs-start;
        my int32 @col-num-refs;
        my int $num-objects;
        my int $num-type-objects;
        my int $num-stables;
        my int $num-frames;
        my int $total-size;


        if $!version == 3 {
            await Promise.in(0.1);
            $snapshot-task<parser>.fetch-collectable-data(
                    toc => $snapshot-task<toc>,
                    index => $snapshot-task<index>,

                    :@col-kinds, :@col-desc-indexes, :@col-size, :@col-unmanaged-size,
                    :@col-refs-start, :@col-num-refs, :$num-objects, :$num-type-objects,
                    :$num-stables, :$num-frames, :$total-size

                    :$progress
                    );
        }

        $updates.emit({ index => $snapshot-task<index>, collectable-progress => 1 }) if $updates;

        hash(
            :@col-kinds, :@col-desc-indexes, :@col-size, :@col-unmanaged-size,
            :@col-refs-start, :@col-num-refs, :$num-objects, :$num-type-objects,
            :$num-stables, :$num-frames, :$total-size
        )
    }

    my $ref-data = start {
        my int8 @ref-kinds;
        my int32 @ref-indexes;
        my int32 @ref-tos;

        if $!version == 3 {
            $snapshot-task<parser>.fetch-references-data(
                    toc => $snapshot-task<toc>,
                    index => $snapshot-task<index>,

                    :@ref-kinds, :@ref-indexes, :@ref-tos

                    :$progress
                    );
        }
        hash(:@ref-kinds, :@ref-indexes, :@ref-tos)
    }

    note "add 5 targets for promises at end of parse-snapshot";
    .add-target(5) with $progress;
    for $!strings-promise, $!types-promise, $!static-frames-promise, $col-data, $ref-data {
        .then({ note "one of the promises at the end of parse-snapshot; increment"; $progress.increment })
    }

    Snapshot.new(
        |(await $col-data),
        |(await $ref-data),
        strings => await($!strings-promise),
        types => await($!types-promise),
        static-frames => await($!static-frames-promise)
    )
}
