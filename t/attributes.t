use strict;
use v5.10;
use Test::More;
use Pandoc::Elements;

my $attr_hash = { classes => [qw(x x y)], answer => '42', id => '0' };

is_deeply attributes {}, [ '', [], [] ], 'empty attributes';
is_deeply attributes(undef), [ '', [], [] ], 'empty attributes (undef)';
is_deeply attributes $attr_hash, 
  [ '0', [qw(x x y)], [ [ answer => '42' ] ] ], 'classes and id';

my @class_hashes = (
    { classes => [qw(foo bar doz)] },
    { class => 'foo bar doz ' },
    { classes => ['doz'], class => " foo\t bar " },
);

foreach (@class_hashes) {
    my $e = CodeBlock attributes $_, '';
    note explain $e->classes;
    is_deeply $e->classes, [qw(foo bar doz)], 'class(es) attributes';
}

done_testing;
