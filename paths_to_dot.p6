say "digraph G \{";

my @curpath;
my @cur-edges;

my %ids;

for lines() -> $_ {
    if $_ eq "" {
        my $recordlabel = '"{' ~ @cur-edges>>.trans(['<', '>'] => ['&lt;', '&gt;']).join(" | ") ~ '}"';
        say "    @curpath[*-1]_edges [shape=record, label=$recordlabel]";
        @curpath.push: @curpath[*-1] ~ "_edges";
        say @curpath.join(" -> ");
        @curpath = ();
        @cur-edges = ();
    } elsif m/ \s+ '--[' (.*?) ']-->' / {
        @cur-edges.push: $0;
    } elsif m/ (.*) ' ' \( $<kind>=[Frame | Object | STable] \) ' ' \( $<id>=[\d+] \) / {
        say "    node_$<id> [label=\"$0\"]";
        @curpath.push: "node_$<id>";
    } elsif m/ .* 'Root (0)'$ / {
        # ignore the root
    } elsif m/ (.*) ' ' \( $<id>=[\d+] \) / {
        my $mangled-id = $0.comb(/<[a..z]>/).join;
        $mangled-id = $mangled-id ~ "_" ~ ++%ids{$mangled-id};
        say "    node_$mangled-id [label=\"$0\"]";
        @curpath.push: "node_$mangled-id";
    }
}

say "}";
