#!/bin/sh
# Generate two trees for timing a comparison: DIR/a and DIR/b with N files
# each (default 100000) in 100 directories of 10 subdirectories of N/1000
# files, 1 to 4 KiB of text each. In b, every 100th file has one changed
# line (1 %), 50 files are missing and 50 extra files exist (one-sided).
#
#   bench/make-trees.sh [DIR [N]]     DIR defaults to $TMPDIR/emrs-dirdiff-bench
#
# DIR must not exist yet; delete it when done. Never point it into the
# repository.
set -eu
dir=${1:-${TMPDIR:-/tmp}/emrs-dirdiff-bench}
n=${2:-100000}
if [ -e "$dir" ]; then
    echo "make-trees.sh: $dir exists; remove it or pick another directory" >&2
    exit 1
fi
mkdir -p "$dir/a" "$dir/b"
perl -e '
    use strict; use warnings;
    my ($dir, $n) = @ARGV;
    my $per = int($n / 1000) || 1;
    my $line = join("", map { chr(97 + $_ % 26) } 0 .. 62) . "\n";
    for my $i (0 .. $n - 1) {
        my $sub = sprintf("d%03d/s%d", int($i / ($per * 10)) % 100, int($i / $per) % 10);
        my $name = "$sub/f$i.txt";
        my $body = join("", map { "$i:$_ $line" } 1 .. 16 + $i % 48);
        for my $side ("a", "b") {
            next if $side eq "b" && $i % 2000 == 1;     # 50 only in a
            my $path = "$dir/$side/$name";
            unless (-d "$dir/$side/$sub") {
                system("mkdir", "-p", "$dir/$side/$sub") == 0 or die;
            }
            my $content = $body;
            $content =~ s/^$i:8 /$i:8 CHANGED /m if $side eq "b" && $i % 100 == 0;
            open(my $fh, ">", $path) or die "$path: $!";
            print $fh $content;
            close($fh);
        }
        if ($i % 2000 == 3) {                         # 50 only in b
            open(my $fh, ">", "$dir/b/$sub/extra$i.txt") or die;
            print $fh $body;
            close($fh);
        }
    }
' "$dir" "$n"
echo "$dir/a $dir/b"
