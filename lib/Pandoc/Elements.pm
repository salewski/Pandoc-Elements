package Pandoc::Elements;
use strict;
use warnings;
use 5.010;

our $VERSION = '0.27';

use Carp;
use JSON qw(decode_json);
use Scalar::Util qw(blessed reftype);
use Pandoc::Walker qw(walk);
use Pandoc::Version;

our $PANDOC_VERSION; # a string like '1.16'
$PANDOC_VERSION ||= eval { Pandoc::Version->new($ENV{PANDOC_VERSION}) };

# internal variables

my $PANDOC_API_MIN = Pandoc::Version->new('1.12.3');    # since pandoc 1.12.1
my $PANDOC_BIN_MIN = Pandoc::Version->new('1.12.1');

# release version => minimal required api version
my @REQUIRED_API = map { Pandoc::Version->new($_) }
    '1.18'   => '1.17',  # pandoc 1.18 has api 1.17.0.4, compatible with api 1.17
    '1.16'   => '1.16',  # pandoc 1.16 has api 1.16
    '1.17'   => '1.16',  # pandoc 1.17 has api 1.16
;

sub _as_pandoc_version {
    (blessed $_[0] and $_[0]->isa('Pandoc::Version'))
        ? $_[0] : Pandoc::Version->new($_[0])
}

sub pandoc_version {
    if (@_) {
        my $doc = shift;
        if (@_) {
            $doc->api_version(
                _minimum_pandoc_api_for(@_)
                    // croak "pandoc version not supported"
            );
        }
        _minimum_api_version_for($doc->api_version);
    } elsif (defined $PANDOC_VERSION) {
        _as_pandoc_version($PANDOC_VERSION)
    } else {
        $REQUIRED_API[0]
    }
}

sub _minimum_api_version_for {
    my $api_version = shift;

    foreach (grep { $_ % 2} 0 .. @REQUIRED_API) { # 1,3,...
        if ($api_version->match($REQUIRED_API[$_]) ) {
            return $REQUIRED_API[$_-1]
        }
    }

    return $api_version >= $PANDOC_API_MIN ? $PANDOC_BIN_MIN : undef;
}

sub _minimum_pandoc_api_for {
    my $version = _as_pandoc_version(shift);
    return if @$version <= 1; # require major.minor

    foreach (grep { $_ % 2} 0 .. @REQUIRED_API) { # 1,3,...
        if ($version->match($REQUIRED_API[$_-1]) ) {
            return $REQUIRED_API[$_]
        }
    }

    return $version >= $PANDOC_BIN_MIN ? $PANDOC_API_MIN : undef;
}

our %ELEMENTS = (

    # BLOCK ELEMENTS
    Plain          => [ Block => 'content' ],
    Para           => [ Block => 'content' ],
    CodeBlock      => [ Block => qw(attr content) ],
    RawBlock       => [ Block => qw(format content) ],
    BlockQuote     => [ Block => 'content' ],
    OrderedList    => [ Block => qw(attr content/items) ],
    BulletList     => [ Block => 'content/items' ],
    DefinitionList => [ Block => 'content/items:[DefinitionPair]' ],
    Header         => [ Block => qw(level attr content) ],
    HorizontalRule => ['Block'],
    Table          => [ Block => qw(caption alignment widths headers rows) ],
    Div            => [ Block => qw(attr content) ],
    Null           => ['Block'],
    LineBlock      => [ Block => qw(content) ],

    # INLINE ELEMENTS
    Str         => [ Inline => 'content' ],
    Emph        => [ Inline => 'content' ],
    Strong      => [ Inline => 'content' ],
    Strikeout   => [ Inline => 'content' ],
    Superscript => [ Inline => 'content' ],
    Subscript   => [ Inline => 'content' ],
    SmallCaps   => [ Inline => 'content' ],
    Quoted      => [ Inline => qw(type content) ],
    Cite        => [ Inline => qw(citations content) ],
    Code        => [ Inline => qw(attr content) ],
    Space       => ['Inline'],
    SoftBreak   => ['Inline'],
    LineBreak   => ['Inline'],
    Math        => [ Inline => qw(type content) ],
    RawInline   => [ Inline => qw(format content) ],
    Link        => [ Inline => qw(attr content target) ],
    Image       => [ Inline => qw(attr content target) ],
    Note        => [ Inline => 'content' ],
    Span        => [ Inline => qw(attr content) ],

    # METADATA ELEMENTS
    MetaBool    => [ Meta => 'content' ],
    MetaString  => [ Meta => 'content' ],
    MetaMap     => [ Meta => 'content' ],
    MetaInlines => [ Meta => 'content' ],
    MetaList    => [ Meta => 'content' ],
    MetaBlocks  => [ Meta => 'content' ],
);

# type constructors
foreach (
    qw(DefaultDelim Period OneParen TwoParens SingleQuote DoubleQuote
    DisplayMath InlineMath AuthorInText SuppressAuthor NormalCitation
    AlignLeft AlignRight AlignCenter AlignDefault DefaultStyle Example
    Decimal LowerRoman UpperRoman LowerAlpha UpperAlpha)
  )
{
    $ELEMENTS{$_} = ['Inline'];
}

use parent 'Exporter';
our @EXPORT = (
    keys %ELEMENTS,
    qw(Document attributes metadata citation pandoc_version pandoc_json pandoc_query)
);
our @EXPORT_OK = ( @EXPORT, 'element' );

# create constructor functions
foreach my $name ( keys %ELEMENTS ) {
    no strict 'refs';    ## no critic

    my ( $parent, @accessors ) = @{ $ELEMENTS{$name} };
    my $numargs = scalar @accessors;
    my $class   = "Pandoc::Document::$name";
    my @parents = map { "Pandoc::Document::$_" } ($parent);
    $parent = join ' ', map { "Pandoc::Document::$_" } $parent,
      map { 'AttributesRole' } grep { $_ eq 'attr' } @accessors;

    eval "package $class; our \@ISA = qw($parent);";

    *{ __PACKAGE__ . "::$name" } = Scalar::Util::set_prototype(
        sub {
            croak "$name expects $numargs arguments, but given " . scalar @_
              if @_ != $numargs;
            my $self = bless { t => $name, c => ( @_ == 1 ? $_[0] : [@_] ) }, $class;
            $self->set_content(@_);
            $self;
        },
        '$' x $numargs
    );

    for ( my $i = 0 ; $i < @accessors ; $i++ ) {
        my $member = @accessors == 1 ? "\$e->{c}" : "\$e->{c}->[$i]";
        my $code = "my \$e = shift; $member = ( 1 == \@_ ? \$_[0] : [\@_] ) if \@_; return";
        # auto-bless on access via accessor (TODO: move to constructor?)
        $code .= $accessors[$i] =~ s/:\[(.+)\]$//
        ? " [ map { bless \$_, 'Pandoc::Document::$1' } \@{$member} ];"
        : " $member;";
        for ( split '/', $accessors[$i] ) {
            *{ $class . "::$_" } = eval "sub { $code }";
        }
    }
}

sub element {
    my $name = shift;
    no strict 'refs';
    croak "undefined element" unless defined $name;
    croak "unknown element $name" unless $ELEMENTS{$name};
    &$name(@_);
}

sub Document {

    my $arg = do {
        if ( @_ == 1 ) {
            my $reftype = reftype $_[0] // '';
            if ( $reftype eq 'ARRAY') {
                # old JSON format
                {
                    meta => $_[0]->[0]->{unMeta},
                    blocks => $_[0]->[1],
                    api_version => 1.16,
                }
            } elsif ( $reftype eq 'HASH' ) {
                $_[0]
            } else {
                croak 'Document: expect array or hash reference'
            }
        } elsif ( @_ == 2 ) {
            # \%meta, \@blocks
            { meta => $_[0], blocks => $_[1] }
        } elsif ( @_ % 2 ) {
            # odd number of args
            croak "Document: too many or ambiguous arguments";
        } else {
            # even number of args: api_version as named parameter
            { meta => shift, blocks => shift, @_ }
        }
    };

    # prefer haskell-style key but accept perl-style and abbreviated key
    my $api_version = $arg->{'pandoc-api-version'}
        // $arg->{pandoc_api_version}
        // $arg->{api_version};

    # We copy values here because $arg may not be a pure AST representation
    my $doc = bless {
        meta   => metadata( $arg->{meta} // {} ),
        blocks => ( $arg->{blocks}       // [] ),
      },
      'Pandoc::Document';

    if (!defined $api_version and defined $arg->{pandoc_version}) {
        $doc->pandoc_version($arg->{pandoc_version});
    } else {
        $doc->api_version($api_version // $REQUIRED_API[1]);
    }

    walk $doc, \&_bless_pandoc_element;

    return $doc;

}

# internal helper method
sub _bless_pandoc_element {
    my $e = shift;
    return $e unless ref $e;
    return $e if blessed $e and $e->isa('Pandoc::Document::Element');

    # TODO: run recursively via set_content (don't require 'walk')
    if ( 'MetaMap' eq $e->{t} ) {
        for my $v ( values %{ $e->{c} } ) {
            _bless_pandoc_element( $v );
        }
    }

    bless $e, 'Pandoc::Document::' . $e->{t};
    $e->upgrade($e) if $e->can('upgrade');
    return $e;
}


# specific accessors

sub Pandoc::Document::DefinitionPair::term        { $_[0]->[0] }
sub Pandoc::Document::DefinitionPair::definitions { $_[0]->[1] }

# additional functions

sub attributes($) {

    my $e = Span(['',[],[]],[]); # to make use of AttributesRole
    $e->keyvals(@_);

    return $e->attr;
}

sub citation($) {
    my $a = shift;
    {
        citationId     => $a->{id}     // "missing",
        citationPrefix => $a->{prefix} // [],
        citationSuffix => $a->{suffix} // [],
        citationMode   => $a->{mode}   // bless(
            { t => 'NormalCitation', c => [] },
            'Pandoc::Document::NormalCitation'
        ),
        citationNoteNum => $a->{num}  // 0,
        citationHash    => $a->{hash} // 1,
    };
}

sub metadata($) {
    my $meta = shift; # TODO: issue #10 and #34
    for my $v ( values %$meta ) {
        $v = _bless_pandoc_element( $v );
    }
    $meta;
}

sub pandoc_json($) {
    shift if $_[0] =~ /^Pandoc::/;

    my $ast = eval { decode_json( $_[0] ) };
    if ($@) {
        $@ =~ s/ at [^ ]+Elements\.pm line \d+//;
        chomp $@;
        croak $@;
    }
    return Document $ast;
}

*pandoc_query = *Pandoc::Walker::query;

# document element packages

{

    package Pandoc::Document;
    use strict;
    use Carp 'croak';
    our $VERSION = '0.04';
    our @ISA = ('Pandoc::Document::Element');
    sub blocks;
    sub name { 'Document' }
    sub meta {
        $_[0]->{meta} = Pandoc::Elements::metadata($_[1]) if @_ > 1;
        $_[0]->{meta};
    }
    sub content {
        $_[0]->{blocks} = $_[1] if @_ > 1;
        $_[0]->{blocks};
    }
    *blocks = \&content;
    sub is_document { 1 }
    sub metavalue {
        my $meta = $_[0]->meta;
        return { map { $_ => $meta->{$_}->metavalue } keys %$meta }
    }
    sub string {
        join '', map { $_->string } @{$_[0]->content}
    }
    sub api_version {
        my $self = shift;
        if ( @_ ) {
            my $version = Pandoc::Version->new(shift);
            croak "api_version must be >= $PANDOC_API_MIN"
                if $version < $PANDOC_API_MIN;
            croak "api_version must have major and minor part"
                if @$version < 2;
            $self->{'pandoc-api-version'} = $version;
        }
        return $self->{'pandoc-api-version'};
    }
    *pandoc_version = \&Pandoc::Elements::pandoc_version;
}

{

    package Pandoc::Document::Element;
    use strict;
    use warnings;
    our $VERSION = $Pandoc::Document::VERSION;
    use JSON ();
    use Scalar::Util qw(reftype blessed);
    use Pandoc::Walker ();
    use subs qw(walk query transform);    # Silence syntax warnings

    sub to_json {
        JSON->new->utf8->canonical->convert_blessed->encode( $_[0] );
    }

    sub TO_JSON {

        # Run everything thru this method so arrays/hashes are cloned
        # and objects without TO_JSON methods are stringified.
        # Required to ensure correct scalar types for Pandoc.

# There is no easy way in Perl to tell if a scalar value is already a string or number,
# so we stringify all scalar values and numify/boolify as needed afterwards.

        my ( $ast, $maybe_blessed ) = @_;
        if ( $maybe_blessed && blessed $ast ) {
            return $ast if $ast->can('TO_JSON');    # JSON.pm will convert
                 # may have overloaded stringification! Should we check?
                 # require overload;
              # return "$ast" if overload::Method($ast, q/""/) or overload::Method($ast, q/0+/);
              # carp "Non-stringifiable object $ast";
            return "$ast";
        }
        elsif ( 'ARRAY' eq reftype $ast ) {
            return [ map { ref($_) ? TO_JSON( $_, 1 ) : "$_"; } @$ast ];
        }
        elsif ( 'HASH' eq reftype $ast ) {
            my %ret = %$ast;
            while ( my ( $k, $v ) = each %ret ) {
                $ret{$k} = ref($v) ? TO_JSON( $v, 1 ) : "$v";
            }
            return \%ret;
        }
        else { return "$ast" }
    }

    sub name        { $_[0]->{t} }
    sub content     {
       my $e = shift;
       $e->set_content(@_) if @_;
       $e->{c}
    }
    sub set_content { # TODO: document this
       my $e = shift;
       $e->{c} = @_ == 1 ? $_[0] : [@_]
    }
    sub is_document { 0 }
    sub is_block    { 0 }
    sub is_inline   { 0 }
    sub is_meta     { 0 }
    *walk      = *Pandoc::Walker::walk;
    *query     = *Pandoc::Walker::query;
    *transform = *Pandoc::Walker::transform;

    sub string {

        # TODO: fix issue #4 to avoid this duplication
        if ( $_[0]->name =~ /^(Str|Code|Math|MetaString)$/ ) {
            return $_[0]->content;
        }
        elsif ( $_[0]->name =~ /^(LineBreak|SoftBreak|Space)$/ ) {
            return ' ';
        }
        join '', @{
            $_[0]->query(
                {
                    'Str|Code|Math|MetaString'  => sub { $_->content },
                    'LineBreak|Space|SoftBreak' => sub { ' ' },
                }
            );
        };
    }

    # TODO: replace by new class Pandoc::Selector with compiled code
    sub match {
        my $self = shift;
        foreach my $selector ( split /\|/, shift ) {
            return 1 if $self->match_simple($selector);
        }
        return 0;
    }

    sub match_simple {
        my ( $self, $selector ) = @_;
        $selector =~ s/^\s+|\s+$//g;

        # name
        return 0
          if $selector =~ s/^([a-z]+)\s*//i and lc($1) ne lc( $self->name );
        return 1 if $selector eq '';

        # type
        if ( $selector =~ s/^:(document|block|inline|meta)\s*// ) {
            my $method = "is_$1";
            return 0 unless $self->$method;
            return 1 if $selector eq '';
        }

        # id and/or classes
        return 0 unless $self->can('match_attributes');
        return $self->match_attributes($selector);
    }

}

{

    package Pandoc::Document::AttributesRole;
    use Hash::MultiValue;
    use Scalar::Util qw(reftype blessed);
    use Carp qw(croak);

    my $IDENTIFIER = qr{\p{L}(\p{L}|[0-9_:.-])*};

    sub id {
        $_[0]->attr->[0] = defined $_[1] ? "$_[1]" : "" if @_ > 1;
        $_[0]->attr->[0]
    }

    sub classes {
        my $e = shift;
        croak 'Method classes() is not a setter' if @_;
        warn "->classes is deprecated, use ->class instead\n";
        $e->attr->[1]
    }

    sub class {
        my $e = shift;
        if (@_) {
            $e->attr->[1] = [
                grep { $_ ne '' }
                map { split qr/\s+/, $_ }
                map { (ref $_ and reftype $_ eq 'ARRAY') ? @$_ : $_ }
                @_
            ];
        }
        join ' ', @{$e->attr->[1]}
    }

    sub add_attribute {
        my ($e, $key, $value) = @_;
        if ($key eq 'id') {
            $e->id($value);
        } elsif ($key eq 'class') {
            $value //= '';
            $value = ["$value"] unless (reftype $value // '') eq 'ARRAY';
            push @{$e->attr->[1]}, grep { $_ ne '' } map { split qr/\s+/, $_ } @$value;
        } else {
            push @{$e->attr->[2]}, [ $key, "$value" ];
        }
    }

    sub keyvals {
        my $e = shift;
        if (@_) {
            my $attrs = @_ == 1 ? shift : Hash::MultiValue->new(@_);
            unless (blessed $attrs and $attrs->isa('Hash::MultiValue')) {
                $attrs = Hash::MultiValue->new(%$attrs);
            }
            $e->attr->[1] = [] if exists $attrs->{class};
            $e->attr->[2] = [];
            $attrs->each(sub { $e->add_attribute(@_) });
        }
        my @h;
        push @h, id => $e->id if $e->id ne '';
        push @h, class => $e->class if @{$e->attr->[1]};
        Hash::MultiValue->new( @h, map { @$_ } @{$e->attr->[2]} );
    }

    # TODO: rename and/or extend to keyvals check
    sub match_attributes {
        my ( $self, $selector ) = @_;
        $selector =~ s/^\s+|\s+$//g;

        while ( $selector ne '' ) {
            if ( $selector =~ s/^#($IDENTIFIER)\s*// ) {
                return 0 unless $self->id eq $1;
            }
            elsif ( $selector =~ s/^\.($IDENTIFIER)\s*// ) {
                return 0 unless grep { $1 eq $_ } @{ $self->attr->[1] };
            }
            else {
                return 0;
            }
        }

        return 1;
    }
}

{

    package Pandoc::Document::Block;
    our $VERSION = $PANDOC::Document::VERSION;
    our @ISA     = ('Pandoc::Document::Element');
    sub is_block { 1 }
}

{

    package Pandoc::Document::Inline;
    our $VERSION = $PANDOC::Document::VERSION;
    our @ISA     = ('Pandoc::Document::Element');
    sub is_inline { 1 }
}

{

    package Pandoc::Document::Meta;
    use Scalar::Util 'reftype';
    our $VERSION = $PANDOC::Document::VERSION;
    our @ISA     = ('Pandoc::Document::Element');
    sub is_meta { 1 }
}

{

    package Pandoc::Document::LinkageRole;
    our $VERSION = $PANDOC::Document::VERSION;

    for my $Element (qw[ Link Image ]) {
        no strict 'refs';    #no critic
        unshift @{"Pandoc::Document::${Element}::ISA"}, __PACKAGE__; # no critic
    }

    sub url   { $_[0]->{c}->[-1][0] }
    sub title { $_[0]->{c}->[-1][1] }

    sub upgrade {
        # prepend attributes to old-style ast
        unshift @{ $_[0]->{c} }, [ "", [], [] ]
            if 2 == @{ $_[0]->{c} };
    }
}

# Special TO_JSON methods to coerce data to int/number/Boolean as appropriate
# and to downgrade document model depending on pandoc_version

sub Pandoc::Document::to_json {
    my ($self) = @_;

    local $Pandoc::Elements::PANDOC_VERSION =
        $Pandoc::Elements::PANDOC_VERSION // $self->pandoc_version;

    return Pandoc::Document::Element::to_json( $self->TO_JSON );
}

sub Pandoc::Document::TO_JSON {
    my ( $self ) = @_;
    return $self->api_version >= 1.17
        ? { %$self }
        : [ { unMeta => $self->{meta} }, $self->{blocks} ]
}

sub Pandoc::Document::SoftBreak::TO_JSON {
    if ( pandoc_version() < '1.16' ) {
        return { t => 'Space', c => [] };
    } else {
        return { t => 'SoftBreak', c => [] };
    }
}

sub Pandoc::Document::LinkageRole::TO_JSON {
    my $ast = Pandoc::Document::Element::TO_JSON( $_[0] );
    if ( pandoc_version() < 1.16 ) {
        # remove attributes
        $ast->{c} = [ @{ $ast->{c} }[ 1, 2 ] ];
    }
    return $ast;
}

sub Pandoc::Document::Header::TO_JSON {
    my $ast = Pandoc::Document::Element::TO_JSON( $_[0] );

    # coerce heading level to int
    $ast->{c}[0] = int( $ast->{c}[0] );
    return $ast;
}

sub Pandoc::Document::OrderedList::TO_JSON {
    my $ast = Pandoc::Document::Element::TO_JSON( $_[0] );

    # coerce first item number to int
    $ast->{c}[0][0] = int( $ast->{c}[0][0] );
    return $ast;
}

sub Pandoc::Document::Table::TO_JSON {
    my $ast = Pandoc::Document::Element::TO_JSON( $_[0] );

    # coerce column widths to numbers (floats)
    $_ += 0 for @{ $ast->{c}[2] };    # faster than map
    return $ast;
}

sub Pandoc::Document::MetaBool::set_content {
    $_[0]->{c} = $_[1] && $_[1] ne 'false' && $_[1] ne 'FALSE'
}

sub Pandoc::Document::MetaBool::TO_JSON {
    return {
        t => 'MetaBool',

        # coerce Bool value to JSON Boolean object
        c => $_[0]->{c} ? JSON::true() : JSON::false(),
    };
}

sub Pandoc::Document::MetaBool::metavalue {
    $_[0]->{c} ? 1 : 0
}

sub Pandoc::Document::MetaMap::metavalue {
    my $map = $_[0]->{c};
    return { map { $_ => $map->{$_}->metavalue } keys %$map }
}

sub Pandoc::Document::MetaInlines::metavalue {
    join '', map { $_->string } @{$_[0]->{c}}
}

sub Pandoc::Document::MetaBlocks::metavalue {
    join "\n", map { $_->string } @{$_[0]->{c}}
}

sub Pandoc::Document::MetaList::metavalue {
    [ map { $_->metavalue } @{$_[0]->{c}} ]
}

sub Pandoc::Document::MetaString::metavalue {
    $_[0]->{c}
}

sub Pandoc::Document::Cite::TO_JSON {
    my $ast = Pandoc::Document::Element::TO_JSON( $_[0] );
    for my $citation ( @{ $ast->{c}[0] } ) {
        for my $key (qw[ citationHash citationNoteNum ]) {

            # coerce to int
            $citation->{$key} = int( $citation->{$key} );
        }
    }
    return $ast;
}

sub Pandoc::Document::LineBlock::TO_JSON {
    my $ast     = Pandoc::Document::Element::TO_JSON( $_[0] );
    my $content = $ast->{c};

    for my $line ( @$content ) {

        # Convert spaces at the beginning of each line
        # to Unicode non-breaking spaces, because pandoc does.
        next unless $line->[0]->{t} eq 'Str';
        $line->[0]->{c} =~ s{^(\x{20}+)}{ "\x{a0}" x length($1) }e;
    }

    return $ast if pandoc_version() >= 1.18;

    my $c = [ map { ; @$_, LineBreak() } @{$content} ];
    pop @$c;    # remove trailing line break
    return Para( $c )->TO_JSON;
}

1;
__END__

=encoding utf-8

=head1 NAME

Pandoc::Elements - create and process Pandoc documents

=begin markdown

# STATUS

[![Build Status](https://travis-ci.org/nichtich/Pandoc-Elements.svg)](https://travis-ci.org/nichtich/Pandoc-Elements)
[![Coverage Status](https://coveralls.io/repos/nichtich/Pandoc-Elements/badge.svg)](https://coveralls.io/r/nichtich/Pandoc-Elements)
[![Kwalitee Score](http://cpants.cpanauthors.org/dist/Pandoc-Elements.png)](http://cpants.cpanauthors.org/dist/Pandoc-Elements)

=end markdown

=head1 SYNOPSIS

The output of this script C<hello.pl>

    use Pandoc::Elements;
    use JSON;

    print Document(
        {
            title => MetaInlines [ Str "Greeting" ]
        },
        [
            Header( 1, attributes { id => 'top' }, [ Str 'Hello' ] ),
            Para [ Str 'Hello, world!' ],
        ],
        api_version => '1.17.0.4'
    )->to_json;

can be converted for instance to HTML via

    ./hello.pl | pandoc -f json -t html5 --standalone

an equivalent Pandoc Markdown document would be

    % Greeting
    # Gruß {.de}
    Hello, world!

=head1 DESCRIPTION

Pandoc::Elements provides utility functions to parse, serialize, and modify
abstract syntax trees (AST) of L<Pandoc|http://pandoc.org/> documents. Pandoc
can convert this data structure to many other document formats, such as HTML,
LaTeX, ODT, and ePUB.

See also module L<Pandoc::Filter>, command line script L<pod2pandoc>, and the
internal modules L<Pandoc::Walker> and L<Pod::Simple::Pandoc>.

=head1 PANDOC VERSIONS

The Pandoc document model is defined in file
L<Text.Pandoc.Definition|https://hackage.haskell.org/package/pandoc-types/docs/Text-Pandoc-Definition.html>
as part of Haskell package
L<pandoc-types|https://hackage.haskell.org/package/pandoc-types>.

Pandoc::Elements is compatible with pandoc-types 1.12.3 (released with pandoc
1.12.1) up to I<at least> pandoc-types-1.17.0.4 (first releases with pandoc
1.18). JSON output of all pandoc releases since 1.12.1 can be parsed with
function C<pandoc_json>, the L</Document> constructor or method C<parse> of
module L<Pandoc>. The AST is always upgraded to pandoc-types 1.17 and
downgraded to another api version on serialization with C<to_json>.

To determine the api version required by a version of pandoc executable since
version 1.18 execute pandoc with the C<--version> option and check which
version of the C<pandoc-types> library pandoc was compiled with.

Beginning with version 1.18 pandoc will not decode a JSON AST representation
unless the major and minor version numbers (Document method C<api_version>)
match those built into that version of pandoc. The following changes in pandoc
document model have been implemented:

=over

=item

pandoc-types 1.17, released for pandoc 1.18, introduced the
L<LineBlock|/LineBlock> element and modified representation
of the root L<Document|/Document> element.

=item

pandoc-types 1.16, released with pandoc 1.16, introduced attributes to L<Link|/Link> and L<Image|/Image> elements

=item

pandoc-types 1.12.3, released with pandoc 1.12.1, modified the representation
of elements to objects with field C<t> and C<c>. This is also the internal
representation of documents used in this module.

=back

=head1 FUNCTIONS

The following functions and keywords are exported by default:

=over

=item

Constructors for all Pandoc document element (L<block elements|/BLOCK ELEMENTS>
such as C<Para> and L<inline elements|/INLINE ELEMENTS> such as C<Emph>,
L<metadata elements|/METADATA ELEMENTS> and the L<Document|/DOCUMENT ELEMENT>).

=item

L<Type keywords|/TYPE KEYWORDS> such as C<Decimal> and C<LowerAlpha> to be used
as types in other document elements.

=item

The following helper functions C<pandoc_json>, C<pandoc_version>,
C<attributes>, C<citation>, and C<element>.

=back

=head2 pandoc_json $json

Parse a JSON string, as emitted by pandoc in JSON format. This is the reverse
to method C<to_json> but it can read both old (before Pandoc 1.16) and new
format.

=head2 attributes { key => $value, ... }

Maps a hash reference or instance of L<Hash::MultiValue> into the internal
structure of Pandoc attributes. The special keys C<id> (string), and C<class>
(string or array reference with space-separated class names) are recognized.
See L<attribute methods|/ATTRIBUTE METHODS> for details.

=head2 citation { ... }

A citation as part of document element L<Cite|/Cite> must be a hash reference
with fields C<citationID> (string), C<citationPrefix> (list of L<inline
elements|/INLINE ELEMENTS>) C<citationSuffix> (list of L<inline
elements|/INLINE ELEMENTS>), C<citationMode> (one of C<NormalCitation>,
C<AuthorInText>, C<SuppressAuthor>), C<citationNoteNum> (integer), and
C<citationHash> (integer). The helper method C<citation> can be used to
construct such hash by filling in default values and using shorter field names
(C<id>, C<prefix>, C<suffix>, C<mode>, C<note>, and C<hash>):

    citation {
        id => 'foo',
        prefix => [ Str "see" ],
        suffix => [ Str "p.", Space, Str "42" ]
    }

    # in Pandoc Markdown

    [see @foo p. 42]

=head2 pandoc_version( [ $document ] )

Return a L<Pandoc::Version> object with expected version number of pandoc
executable to be used for serializing documents with L<to_json|/to_json>.

If a L<Document element|/DOCUMENT ELEMENT> is given as argument, the minimal
pandoc release version compatible with its api version is returned.

Without argument, package variable C<$PANDOC_VERSION> is checked for a
preferred pandoc release. By default this variable is set from an environment
variable of same name. If no preferred pandoc release has been specified, the
function returns version 1.18 because this is the first pandoc release
compatible with most recent api version supported by this module.

See also method C<version> of module L<Pandoc> to get the current version of
pandoc executable on your system.

=head2 element( $name => $content )

Create a Pandoc document element of arbitrary name. This function is only
exported on request.

=head1 ELEMENTS AND METHODS

Document elements are encoded as Perl data structures equivalent to the JSON
structure, emitted with pandoc output format C<json>. This JSON structure is
subject to minor changes between L<versions of pandoc|/pandoc_version>.  All
elements are blessed objects that provide L<common element methods|/COMMON
METHODS> (all elements), L<attribute methods|/ATTRIBUTE METHODS> (elements with
attributes), and additional element-specific methods.

=head2 COMMON METHODS

=head3 to_json

Return the element as JSON encoded string. The following are equivalent:

    $element->to_json;
    JSON->new->utf8->canonical->convert_blessed->encode($element);

The serialization format can be adjusted to different L<pandoc versions|/PANDOC
VERSIONS> with module and environment variable C<PANDOC_VERSION> or with
Document element properties C<api_version> and C<pandoc_version>.

When writing filters you can normally just rely on the api version value
obtained from pandoc, since pandoc expects to receive the same JSON format as
it emits.

=head3 name

Return the name of the element, e.g. "Para" for a L<paragraph element|/Para>.

=head3 content

Return the element content. For most elements (L<Para|/Para>, L<Emph|/Emph>,
L<Str|/Str>...) the content is an array reference with child elements. Other
elements consist of multiple parts; for instance the L<Link|/Link> element has
attributes (C<attr>, C<id>, C<class>, C<classes>, C<keyvals>) a link text
(C<content>) and a link target (C<target>) with C<url> and C<title>.

=head3 is_block

True if the element is a L<Block element|/BLOCK ELEMENTS>

=head3 is_inline

True if the element is an inline L<Inline element|/INLINE ELEMENTS>

=head3 is_meta

True if the element is a L<Metadata element|/METADATA ELEMENTS>

=head3 is_document

True if the element is a L<Document element|/DOCUMENT ELEMENT>

=head3 walk(...)

Walk the element tree with L<Pandoc::Walker>

=head3 query(...)

Query the element to extract results with L<Pandoc::Walker>

=head3 transform(...)

Transform the element tree with L<Pandoc::Walker>

=head3 string

Returns a concatenated string of element content, leaving out all formatting.

=head2 ATTRIBUTE METHODS

Some elements have attributes which can be an identifier, ordered class names
and ordered key-value pairs. Elements with attributes provide the following
methods:

=head3 attr

Get or set the attributes in Pandoc internal structure:

  [ $id, [ @classes ], [ [ key => $value ], ... ] ]

See helper function L<attributes|/attributes-key-value> to create this
structure.

=head3 keyvals

Get all attributes (id, class, and key-value pairs) as new L<Hash::MultiValue>
instance, or replace I<all> key-value pairs plus id and/or class if these are
included as field names. All class fields are split by whitespaces.

  $e->keyvals                           # return new Hash::MultiValue
  $e->keyvals( $HashMultiValue )        # update by instance of Hash::MultiValue
  $e->keyvals( key => $value, ... )     # update by list of key-value pairs
  $e->keyvals( \%hash )                 # update by hash reference
  $e->keyvals( { } )                    # remove all key-value pairs
  $e->keyvals( id => '', class => '' )  # remove all key-value pairs, id, class

=head3 id

Get or set the identifier. See also L<Pandoc::Filter::HeaderIdentifiers> for
utility functions to handle L<Header|/Header> identifiers.

=head3 class

Get or set the list of classes, separated by whitespace.

=head3 add_attribute( $name => $value )

Append an attribute. The special attribute names C<id> and C<class> set or
append identifier or class, respectively.

=head2 DOCUMENT ELEMENT

=head3 Document

Root element, consisting of metadata hash (C<meta>), document element array
(C<content>=C<blocks>) and optional C<api_version>. The constructor accepts
either two arguments and an optional named parameter C<api_version>:

    Document { %meta }, [ @blocks ], api_version => $version_string

or a hash with three fields for metadata, document content, and an optional
pandoc API version:

    {
        meta               => { %metadata },
        blocks             => [ @content ],
        pandoc-api-version => [ $major, $minor, $revision ]
    }

The latter form is used as pandoc JSON format since pandoc release 1.18. If no
api version is given, it will be set 1.17 which was also introduced with pandoc
release 1.18.

A third ("old") form is accepted for compatibility with pandoc JSON format
before release 1.18 and since release 1.12.1: an array with two elements for
metadata and document content respectively.

    [ { unMeta => { %meta } }, [ @blocks ] ]

The api version is set to 1.16 in this case, but older versions down to 1.12.3
used the same format.

Document elements provide the following special methods in addition to
L<common element methods|/COMMON METHODS>:

=over

=item B<api_version( [ $api_version ] )>

Return the pandoc-types version (aka "pandoc-api-version") of this document as
L<Pandoc::Version|Pandoc::Version> object or sets it to a new value. This
version determines how method L<to_json|/to_json> serializes the document.

See L</PANDOC VERSIONS> for details.

=item B<pandoc_version( [ $pandoc_version ] )>

Return the minimum required version of pandoc executable compatible
with the api_version of this document. The following are equivalent:

  $doc->pandoc_version;
  pandoc_version( $doc );

If used as setter, sets the api version of this document to be compatible with
the given pandoc version.

=item B<content> or B<blocks>

Get or set the array of L<block elements|/BLOCK ELEMENTS> of the
document.

=item B<meta>

Return document L<metadata elements|/METADATA ELEMENTS>.

=item B<metavalue>

Returns a copy of the metadata hash with all L<metadata elements|/METADATA
ELEMENTS> flattened to unblessed values:

    $doc->metavalue   # equivalent to
    { map { $_ => $doc->meta->{$_}->metavalue } keys %{$doc->meta} }

=back

=head2 BLOCK ELEMENTS

=head3 BlockQuote

Block quote, consisting of a list of L<blocks|/BLOCK ELEMENTS> (C<content>)

    BlockQuote [ @blocks ]

=head3 BulletList

Unnumbered list of items (C<content>=C<items>), each a list of
L<blocks|/BLOCK ELEMENTS>

    BulletList [ [ @blocks ] ]

=head3 CodeBlock

Code block (literal string C<content>) with attributes (C<attr>, C<id>,
C<class>, C<classes>, C<keyvals>)

    CodeBlock $attributes, $content

=head3 DefinitionList

Definition list, consisting of a list of pairs (C<content>=C<items>),
each a term (C<term>, a list of L<inlines|/INLINE ELEMENTS>) and one
or more definitions (C<definitions>, a list of L<blocks|/BLOCK ELEMENTS>).

    DefinitionList [ @definitions ]

    # each item in @definitions being a pair of the form

        [ [ @inlines ], [ @blocks ] ]

=head3 Div

Generic container of L<blocks|/BLOCK ELEMENTS> (C<content>) with attributes
(C<attr>, C<id>, C<class>, C<classes>, C<keyvals>).

    Div $attributes, [ @blocks ]

=head3 Header

Header with C<level> (integer), attributes (C<attr>, C<id>, C<class>,
C<classes>, C<keyvals>), and text (C<content>, a list of L<inlines|/INLINE ELEMENTS>).

    Header $level, $attributes, [ @inlines ]

=head3 HorizontalRule

Horizontal rule

    HorizontalRule

=head3 LineBlock

List of lines (C<content>), each a list of L<inlines|/INLINE ELEMENTS>.

    LineBlock [ @lines ]

This element was added in pandoc 1.18. Before it was represented L<Para|/Para>
elements with embedded L<LineBreak|/LineBreak> elements. This old serialization
form can be enabled by setting C<$PANDOC_VERSION> package variable to a lower
version number.

=head3 Null

Nothing

    Null

=head3 OrderedList

Numbered list of items (C<content>=C<items>), each a list of L<blocks|/BLOCK
ELEMENTS>), preceded by list attributes (start number, numbering style, and
delimiter).

    OrderedList [ $start, $style, $delim ], [ [ @blocks ] ]

Supported styles are C<DefaultStyle>, C<Example>, C<Decimal>, C<LowerRoman>,
C<UpperRoman>, C<LowerAlpha>, and C<UpperAlpha>.

Supported delimiters are C<DefaultDelim>, C<Period>, C<OneParen>, and
C<TwoParens>.

=head3 Para

Paragraph, consisting of a list of L<Inline elements|/INLINE ELEMENTS>
(C<content>).

    Para [ $elements ]

=head3 Plain

Plain text, not a paragraph, consisting of a list of L<Inline elements|/INLINE
ELEMENTS> (C<content>).

    Plain [ @inlines ]

=head3 RawBlock

Raw block with C<format> and C<content> string.

    RawBlock $format, $content

=head3 Table

Table, with C<caption>, column C<alignments>, relative column C<widths> (0 =
default), column C<headers> (each a list of L<blocks|/BLOCK ELEMENTS>), and
C<rows> (each a list of lists of L<blocks|/BLOCK ELEMENTS>).

    Table [ @inlines ], [ @alignments ], [ @width ], [ @headers ], [ @rows ]

Possible alignments are C<AlignLeft>, C<AlignRight>, C<AlignCenter>, and
C<AlignDefault>.

An example:

    Table [Str "Example"], [AlignLeft,AlignRight], [0.0,0.0],
     [[Plain [Str "name"]]
     ,[Plain [Str "number"]]],
     [[[Plain [Str "Alice"]]
      ,[Plain [Str "42"]]]
     ,[[Plain [Str "Bob"]]
      ,[Plain [Str "23"]]]];

=head2 INLINE ELEMENTS

=head3 Cite

Citation, a list of C<citations> and a list of L<inlines|/INLINE ELEMENTS>
(C<content>). See helper function L<citation|/citation> to construct
citations.

    Cite [ @citations ], [ @inlines ]

=head3 Code

Inline code, a literal string (C<content>) with attributes (C<attr>, C<id>,
C<class>, C<classes>, C<keyvals>)

    Code attributes { %attr }, $content

=head3 Emph

Emphasized text, a list of L<inlines|/INLINE ELEMENTS> (C<content>).

    Emph [ @inlines ]

=head3 Image

Image with alt text (C<content>, a list of L<inlines|/INLINE ELEMENTS>) and
C<target> (list of C<url> and C<title>) with attributes (C<attr>, C<id>,
C<class>, C<classes>, C<keyvals>).

    Image attributes { %attr }, [ @inlines ], [ $url, $title ]

Serializing the attributes is disabled in api version less then 1.16.

=head3 LineBreak

Hard line break

    LineBreak

=head3 Link

Hyperlink with link text (C<content>, a list of L<inlines|/INLINE ELEMENTS>)
and C<target> (list of C<url> and C<title>) with attributes (C<attr>, C<id>,
C<class>, C<classes>, C<keyvals>).

    Link attributes { %attr }, [ @inlines ], [ $url, $title ]

Serializing the attributes is disabled in api version less then 1.16.

=head3 Math

TeX math, given as literal string (C<content>) with C<type> (one of
C<DisplayMath> and C<InlineMath>).

    Math $type, $content

=head3 Note

Footnote or Endnote, a list of L<blocks|/BLOCK ELEMENTS> (C<content>).

    Note [ @blocks ]

=head3 Quoted

Quoted text with quote C<type> (one of C<SingleQuote> and C<DoubleQuote>) and a
list of L<inlines|/INLINE ELEMENTS> (C<content>).

    Quoted $type, [ @inlines ]

=head3 RawInline

Raw inline with C<format> (a string) and C<content> (a string).

    RawInline $format, $content

=head3 SmallCaps

Small caps text, a list of L<inlines|/INLINE ELEMENTS> (C<content>).

    SmallCaps [ @inlines ]

=head3 SoftBreak

Soft line break

    SoftBreak

This element was added in pandoc 1.16 as a matter of editing convenience to
preserve line breaks (as opposed to paragraph breaks) from input source to
output. If you are going to feed a document containing C<SoftBreak> elements to
Pandoc E<lt> 1.16 you will have to set the package variable or environment
variable C<PANDOC_VERSION> to 1.15 or below.

=head3 Space

Inter-word space

    Space

=head3 Span

Generic container of L<inlines|/INLINE ELEMENTS> (C<content>) with attributes
(C<attr>, C<id>, C<class>, C<classes>, C<keyvals>).

    Span attributes { %attr }, [ @inlines ]

=head3 Str

Plain text, a string (C<content>).

    Str $content

=head3 Strikeout

Strikeout text, a list of L<inlines|/INLINE ELEMENTS> (C<content>).

    Strikeout [ @inlines ]

=head3 Strong

Strongly emphasized text, a list of L<inlines|/INLINE ELEMENTS> (C<content>).

    Strong [ @inlines ]

=head3 Subscript

Subscripted text, a list of L<inlines|/INLINE ELEMENTS> (C<content>).

    Supscript [ @inlines ]

=head3 Superscript

Superscripted text, a list of L<inlines|/INLINE ELEMENTS> (C<content>).

    Superscript [ @inlines ]

=head2 METADATA ELEMENTS

Metadata can be provided in YAML syntax or via command line option C<-M>.  All
metadata elements return true for C<is_meta>.  Metadata elements can be
converted to unblessed Perl array references, hash references, and scalars with
method C<metavalue>.  On the document level, metadata (document method C<meta>)
is a hash reference with values being metadata elements. Document method
C<metavalue> returns a flattened copy of this hash.

=head3 MetaString

A plain text string metadata value (C<content>).

    MetaString $content

MetaString values can also be set via pandoc command line client:

    pandoc -M key=$content

=head3 MetaBool

A Boolean metadata value (C<content>). The special values C<"false"> and
C<"FALSE"> are recognized as false in addition to normal false values (C<0>,
C<undef>, C<"">...).

    MetaBool $content

MetaBool values can also be set via pandoc command line client:

    pandoc -M key=true
    pandoc -M key=false

=head3 MetaInlines

Container for a list of L<inlines|/INLINE ELEMENTS> (C<content>) in metadata.

    MetaInlines [ @inlines ]

=head3 MetaBlocks

Container for a list of L<blocks|/BLOCK ELEMENTS> (C<content>) in metadata.

    MetaInlines [ @blocks ]

=head3 MetaList

A list of other L<metadata elements|/METADATA ELEMENTS> (C<content>).

    MetaList [ @values ]

=head3 MetaMap

A map of keys to other metadata elements.

    MetaMap { %map }

=head2 TYPE KEYWORDS

The following document elements are only as used as type keywords in other
document elements:

=over

=item

C<SingleQuote>, C<DoubleQuote>

=item

C<DisplayMath>, C<InlineMath>

=item

C<AuthorInText>, C<SuppressAuthor>, C<NormalCitation>

=item

C<AlignLeft>, C<AlignRight>, C<AlignCenter>, C<AlignDefault>

=item

C<DefaultStyle>, C<Example>, C<Decimal>, C<LowerRoman>, C<UpperRoman>,
C<LowerAlpha>, C<UpperAlpha>

=item

C<DefaultDelim>, C<Period>, C<OneParen>, C<TwoParens>

=back

=head1 SEE ALSO

Perl module L<Pandoc> implements a wrapper around the pandoc executable.

Similar libraries in other programming languages are listed at L<https://github.com/jgm/pandoc/wiki/Pandoc-wrappers-and-interfaces>.

=head1 AUTHOR

Jakob Voß E<lt>jakob.voss@gbv.deE<gt>

=head1 CONTRIBUTORS

Benct Philip Jonsson E<lt>bpjonsson@gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2014- Jakob Voß

GNU General Public License, Version 2

This module is heavily based on Pandoc by John MacFarlane.

=cut
