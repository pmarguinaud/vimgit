package vimgit::calltree;

# call tree buffers : a routine and the routines it calls (:CT), drawn sideways, each
# routine in the middle of the routines it calls, on its right :
#
#         ┌── CPG_GP_TENC
#         │
# CPG ────┼── ABOR1 [+8]
#         │
#         └── CPG_DYN_SLG (see line 12)
#
# the routines calling it (:CTR) are drawn the other way, callers on the left :
#
# ARO_RAIN_ICE ──┐
#                │
#   FOO_RAIN ────┴──── RAIN_ICE
#
# the definitions of the routines are in a file next to the tree (.loc instead of .txt),
# one line per line of the tree : for each routine, its byte column, the byte length of
# its label and its definition (empty when there is none), separated by tabs

use strict;

use File::Basename;
use File::Path;
use FileHandle;
use Encode qw (encode_utf8);
use List::Util qw (max);

use base qw (vimgit::file);

# lines of the drawing; the connector of the children of a routine, on its row, from
# the left (:CT) or from the right (:CTR)

my ($H, $V) = ("\x{2500}", "\x{2502}");

my %JOIN   = ("\x{2502}" => "\x{2524}", "\x{250c}" => "\x{252c}", "\x{251c}" => "\x{253c}",
              "\x{2514}" => "\x{2534}", $H => $H);
my %MIRROR = ("\x{250c}" => "\x{2510}", "\x{2514}" => "\x{2518}", "\x{251c}" => "\x{2524}",
              $H => $H, $V => $V, ' ' => ' ');
my %MJOIN  = ($V => "\x{251c}", "\x{2510}" => "\x{252c}", "\x{2524}" => "\x{253c}",
              "\x{2518}" => "\x{2534}", $H => $H);

sub new
{
  my $class = shift;
  my $self = bless { @_ }, $class;
  return $self;
}

sub filename
{
  my ($class, %args) = @_;
  my $f = "$args{editor}{TOP}/calltree=/" . lc ($args{word});
  $f .= '.callers' if ($args{callers});
  $f .= ".depth=$args{depth}" if (defined ($args{depth}));
  return "$f.txt";
}

sub locfile
{
  my $f = shift;
  $f =~ s/\.txt$/.loc/o;
  return $f;
}

sub create
{

# build the tree of routine $args{word}, write it, open it; depth : levels shown below the
# routine; callers : routines calling it instead of routines it calls

  my ($class, %args) = @_;

  my $edtr    = $args{editor};
  my $ws      = $edtr->{workspace};
  my $word    = lc ($args{word});
  my $depth   = $args{depth};
  my $callers = $args{callers};

  unless ($ws->refresh ())
    {
      &VIM::Msg ('The indexes have no call information: run vimgit -i');
      return;
    }

  my @root = $ws->definitions ($word);

  unless (@root)
    {
      &VIM::Msg ("`$word' definition was not found");
      return;
    }

# nodes : { name, note, loc, kids, see (node expanded elsewhere) }; first : definition ->
# node where it is expanded; onpath : definitions being expanded (recursion)

  my (%first, %onpath);

  my $walk;
  $walk = sub
  {
    no warnings 'recursion';

    my ($d, $level, $others) = @_;

    my $loc = "$d->{file}:$d->{line}";

    if (my $n = $first{$d->{key}})
      {
        return { name => $d->{name}, loc => $loc, see => $n, recursive => $onpath{$d->{key}} };
      }

    my $node = { name => $d->{name}, note => ($others ? "[+$others]" : ''), loc => $loc, kids => [] };
    $first{$d->{key}} = $node;

    my @child = $callers ? (grep { ! $ws->blacklisted ($_->{name}) } $ws->callers ($d->{name}))
                         : (grep { ! $ws->blacklisted ($_) } $ws->callees ($d));

    if (defined ($depth) && ($level >= $depth))
      {
        $node->{note} = join (' ', grep { $_ } $node->{note}, '...') if (@child);
        return $node;
      }

    $onpath{$d->{key}} = 1;

    if ($callers)
      {
        push @{ $node->{kids} }, $walk->($_, $level + 1, 0) for (@child);
      }
    else
      {
        my %seen;
        for my $name (grep { ! $seen{$_}++ } @child)
          {
            if ($name =~ m/%/o)
              {
                push @{ $node->{kids} }, { name => $name, note => '(type-bound)', loc => '' };
                next;
              }
            my @d = $ws->definitions ($name, caller => $d);
            unless (@d)
              {
                push @{ $node->{kids} }, { name => $name, note => '(not found)', loc => '' };
                next;
              }
            push @{ $node->{kids} }, $walk->($d[0], $level + 1, scalar (@d) - 1);
          }
      }

    delete $onpath{$d->{key}};

    return $node;
  };

  my $root = $walk->($root[0], 0, scalar (@root) - 1);

# rows first : "see line N" notes need them; then the drawing

  my $nrow = &place_ ($root, 0);

  for my $n (values (%first), &nodes_ ($root))
    {
      $n->{note} = sprintf ('(%ssee line %d)', ($n->{recursive} ? 'recursive, ' : ''), $n->{see}{row} + 1)
        if ($n->{see});
    }

  my $block = &block_ ($root, $callers);

  my $filename = $class->filename (%args);
  &mkpath (&dirname ($filename));

  my $fh = 'FileHandle'->new (">$filename");
  my $fl = 'FileHandle'->new ('>' . &locfile ($filename));
  for my $row (@{ $block->{rows} })
    {
      my ($text, $labels) = @$row;
      $text =~ s/\s+$//o;
      $fh->print (&encode_utf8 ($text) . "\n");
      $fl->print (join ("\t", map { my ($col, $len, $n) = @$_;
                                    my $b = length (&encode_utf8 (substr ($text, 0, $col)));
                                    ($b, length (&encode_utf8 (substr ($text, $col, $len))), $n->{loc}) } @$labels) . "\n");
    }
  $fh->close ();
  $fl->close ();

# a buffer holding a previous tree is replaced; the cursor on the routine

  &VIM::DoCommand ("silent! bwipeout $filename");
  &VIM::DoCommand ("silent view $filename");
  &VIM::DoCommand ('setlocal nowrap nofoldenable');
  &VIM::DoCommand (':' . ($root->{row} + 1));
  &VIM::DoCommand ('normal! ' . ($callers ? '$' : '0'));

  &VIM::Msg (sprintf ("%s %s: %d lines, %d routines", ($callers ? 'Callers of' : 'Call tree of'), uc ($word),
                      $nrow, scalar (keys (%first))));

  return $class->new (file => $filename);
}

sub nodes_
{
  my $n = shift;
  no warnings 'recursion';
  return ($n, map { &nodes_ ($_) } @{ $n->{kids} || [] });
}

sub place_
{

# rows of node $n and its subtree, from row $top : a routine without children takes one row,
# the subtrees of children are separated by an empty row, a routine is in the middle of its
# children; returns the number of rows

  my ($n, $top) = @_;
  no warnings 'recursion';

  my @kids = @{ $n->{kids} || [] };

  unless (@kids)
    {
      $n->{row} = $top;
      return 1;
    }

  my $t = $top;
  for my $k (@kids)
    {
      $t += &place_ ($k, $t) + 1;
    }

  $n->{row} = int (($kids[0]{row} + $kids[-1]{row}) / 2);

  return $t - $top - 1;
}

sub block_
{

# drawing of node $n and its subtree : { rows => [ [ text, [ [ column, length, node ] ] ] ],
# width }; mirror : children on the left; rows of a mirrored block all have its width

  my ($n, $mirror) = @_;
  no warnings 'recursion';

  my $label = uc ($n->{name}) . ($n->{note} ? " $n->{note}" : '');
  my $len = length ($label);

  my @kids = @{ $n->{kids} || [] };

  return { rows => [ [ $label, [ [ 0, $len, $n ] ] ] ], width => $len } unless (@kids);

  my @B = map { &block_ ($_, $mirror) } @kids;
  my $W = &max (map { $_->{width} } @B);

# rows of the children : [ connector, rest of the connector, block row, block, child ];
# an empty row between children

  my @C;
  for my $i (0 .. $#B)
    {
      my $b = $B[$i];
      push @C, [ $V, '   ', undef, $b ] if ($i > 0);
      push @C, [ undef, '   ', $_, $b, $i ] for (@{ $b->{rows} });
    }

# connectors, from the rows of the children; this routine on row $mid of the block

  my $top = &top_ ($kids[0]);
  my $mid = $n->{row} - $top;

  my $row = $top;
  for my $c (@C)
    {
      unless (defined ($c->[2]))
        {
          $row++;
          next;
        }
      my $i = $c->[4];
      my $arow = $kids[$i]{row};
      if ($row == $arow)
        {
          $c->[0] = (@kids == 1) ? $H : ($i == 0) ? "\x{250c}" : ($i == $#kids) ? "\x{2514}" : "\x{251c}";
          $c->[1] = "$H$H ";
        }
      elsif ($row < $arow)
        {
          $c->[0] = ($i == 0) ? ' ' : $V;
        }
      else
        {
          $c->[0] = ($i == $#kids) ? ' ' : $V;
        }
      $row++;
    }

  my @rows;
  my $width = $mirror ? $W + 4 + $len + 5 : 0;

  for my $j (0 .. $#C)
    {
      my ($conn, $rest, $brow, $b) = @{ $C[$j] };
      my ($text, $labels) = $brow ? @$brow : ('', []);
      my $atmid = ($j == $mid);

      if ($mirror)
        {
          my $pad = $W - $b->{width};
          $text = (' ' x $pad) . ($brow ? $text : (' ' x $b->{width}));
          $conn = $MIRROR{$conn};
          $conn = $MJOIN{$conn} if ($atmid);
          $rest = reverse ($rest);
          my $line = $text . $rest . $conn . ($atmid ? "$H$H$H$H $label" : (' ' x ($len + 5)));
          my @l = map { [ $_->[0] + $pad, $_->[1], $_->[2] ] } @$labels;
          push @l, [ $W + 4 + 5, $len, $n ] if ($atmid);
          push @rows, [ $line, \@l ];
        }
      else
        {
          $conn = $JOIN{$conn} if ($atmid);
          my $line = ($atmid ? "$label $H$H$H$H" : (' ' x ($len + 5))) . $conn . $rest . $text;
          my @l = map { [ $_->[0] + $len + 5 + 4, $_->[1], $_->[2] ] } @$labels;
          unshift @l, [ 0, $len, $n ] if ($atmid);
          push @rows, [ $line, \@l ];
          $width = &max ($width, length ($line));
        }
    }

  return { rows => \@rows, width => $width };
}

sub top_
{

# first row of the subtree of node $n

  my $n = shift;
  no warnings 'recursion';
  my @kids = @{ $n->{kids} || [] };
  return @kids ? &top_ ($kids[0]) : $n->{row};
}

sub locations_
{
  my $self = shift;
  my $fh = 'FileHandle'->new ('<' . &locfile ($self->{file})) or return ();
  chomp (my @loc = <$fh>);
  return map { [ split (m/\t/o, $_, -1) ] } @loc;
}

sub do_find
{

# <TAB> : on a name, search the name; ² : on a name, open the definition (pick list for
# [+n]); both keys on "see line N" : go to line N

  my ($self, %args) = @_;

  my $edtr = $args{editor};
  my $hist = $args{hist};

  my $curbuf = $edtr->getcurbuf ();
  my ($row, $col) = $edtr->getcurwin ()->Cursor ();
  my ($line) = $curbuf->Get ($row);

# the routine under the cursor : the label starting before the cursor

  my @r = @{ ($self->locations_ ())[$row - 1] || [] };
  my ($start, $len, $target);
  while (my ($b, $l, $loc) = splice (@r, 0, 3))
    {
      ($start, $len, $target) = ($b, $l, $loc) if (($b <= $col) && ($col < $b + $l));
    }

  return unless (defined ($start));

  my ($name, $note) = (substr ($line, $start, $len) =~ m/^(\S+)\s*(.*)$/o);

  if (($col >= $start + length ($name)) && ($note =~ m/see line (\d+)/o))
    {
      return &VIM::DoCommand (":$1");
    }

  return $edtr->find (word => $name, hist => $hist) unless ($args{defn});

  return &VIM::Msg ("No definition for $name") unless ($target);

# several definitions : the one of the tree first, then the others

  if ($note =~ m/\[\+\d+\]/o)
    {
      my $ws = $edtr->{workspace};
      $ws->refresh ();
      my @P = ($target, grep { $_ ne $target } map { "$_->{file}:$_->{line}" } $ws->definitions (lc ($name)));
      $target = $edtr->pick (@P) or return;
    }

  return $edtr->edit (files => [ $target ], hist => $hist);
}

1;
