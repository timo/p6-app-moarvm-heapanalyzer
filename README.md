# MoarVM Heap Snapshot Analyzer

This is a command line application for analyzing MoarVM heap snapshots. First,
obtain a heap snapshot file from something running on MoarVM. For example:

    $ perl6 --profile=snapshot.mvmheap something.p6

Alternatively, rakudo's built-in module Telemetry has a `snap` sub that you
can invoke with the named argument `:heap` to only take heap snapshots when
your code wants it, rather than every time a GC run happens.

Then run this application on the heap snapshot file it produces (the filename
will be at the end of the program output).

    zef install App::MoarVM::HeapAnalyzer
    moar-ha heap-snapshot-1473849090.9

Type `help` inside the shell to learn about the set of supported commands.
You may also find [these](https://6guts.wordpress.com/2016/03/27/happy-heapster/)
[two](https://6guts.wordpress.com/2016/04/15/heap-heap-hooray/) posts on the
6guts blog about using the heap analyzer to hunt leaks interesting also.
