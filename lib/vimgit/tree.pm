package vimgit::tree;

# trees drawn sideways (call trees, type trees) : each node in the middle of its children,
# on its right :
#
#         ┌── CPG_GP_TENC
#         │
# CPG ────┼── ABOR1 [+8]
#         │
#         └── CPG_DYN_SLG (see line 12)
#
# or, mirrored, on its left :
#
# ARO_RAIN_ICE ──┐
#                │
#   FOO_RAIN ────┴──── RAIN_ICE
#
# a node : { parts => [ [ text, location, pick ], ... ], note, kids => [ node, ... ], see
# (node expanded elsewhere), recursive }; its label is the text of its parts, then its note.
# A part with a location ("file:line", empty when there is none) is a name : ² opens the
# location, or, with pick ("routine:name", "type:name"), gives the list of the definitions
# of the name.
#
# the parts of the labels are in a file next to the tree (.loc instead of .txt), one line
# per line of the tree : for each part, its byte column, its byte length, its location
# ("=N" for "(see line N)") and its pick, separated by tabs

use strict;

use File::Basename;
use File::Path;
use FileHandle;
use Encode qw (encode_utf8);
use List::Util qw (max);

use base qw (vimgit::file);

# lines of the drawing; the connector of the children of a node, on its row, from the left,
# or from the right (mirror)

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

sub locfile
{
  my $f = shift;
  $f =~ s/\.txt$/.loc/o;
  return $f;
}

sub label_
{
  my $n = shift;
  return join ('', map { $_->[0] } @{ $n->{parts} }) . ($n->{note} ? " $n->{note}" : '');
}

sub draw
{

# draw the tree of node $args{root} in file $args{filename}, open it, the cursor on the
# root; mirror : children on the left; returns the number of lines

  my ($class, %args) = @_;

  my ($root, $filename, $mirror) = @args{qw (root filename mirror)};

# rows first : "see line N" notes need them; then the drawing

  my $nrow = &place_ ($root, 0);

  for my $n (&nodes_ ($root))
    {
      next unless ($n->{see});
      $n->{seenote} = sprintf ('(%ssee line %d)', ($n->{recursive} ? 'recursive, ' : ''), $n->{see}{row} + 1);
      $n->{note} = join (' ', grep { $_ } $n->{note}, $n->{seenote});
    }

  my $block = &block_ ($root, $mirror);

  &mkpath (&dirname ($filename));

  my $fh = 'FileHandle'->new (">$filename");
  my $fl = 'FileHandle'->new ('>' . &locfile ($filename));
  for my $row (@{ $block->{rows} })
    {
      my ($text, $labels) = @$row;
      $text =~ s/\s+$//o;
      my @e;
      my $bytes = sub { length (&encode_utf8 ($_[0])) };
      for (@$labels)
        {
          my ($col, $len, $n) = @$_;
          for my $p (@{ $n->{parts} })
            {
              push @e, $bytes->(substr ($text, 0, $col)), $bytes->($p->[0]), $p->[1], $p->[2] || ''
                if (defined ($p->[1]));
              $col += length ($p->[0]);
            }
          if ($n->{seenote})
            {
              $col += length ($n->{note}) - length ($n->{seenote}) + 1;
              push @e, $bytes->(substr ($text, 0, $col)), length ($n->{seenote}), '=' . ($n->{see}{row} + 1), '';
            }
        }
      $fh->print (&encode_utf8 ($text) . "\n");
      $fl->print (join ("\t", @e) . "\n");
    }
  $fh->close ();
  $fl->close ();

# a buffer holding a previous tree is replaced; the cursor on the root

  &VIM::DoCommand ("silent! bwipeout $filename");
  &VIM::DoCommand ("silent view $filename");
  &VIM::DoCommand ('setlocal nowrap nofoldenable');
  &VIM::DoCommand (':' . ($root->{row} + 1));
  &VIM::DoCommand ('normal! ' . ($mirror ? '$' : '0'));

  return $nrow;
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

  my $label = &label_ ($n);
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

# entries of row $row of the .loc file : [ column, length, location, pick ]

  my ($self, $row) = @_;
  my $fh = 'FileHandle'->new ('<' . &locfile ($self->{file})) or return ();
  my $l;
  $l = <$fh> for (1 .. $row);
  return () unless (defined ($l));
  chomp ($l);
  my @f = split (m/\t/o, $l, -1);
  my @e;
  push @e, [ splice (@f, 0, 4) ] while (@f >= 4);
  return @e;
}

sub do_find
{

# <TAB> : search the word under the cursor; ² : on a name, open its location (pick list for
# names with several definitions); both keys on "see line N" : go to line N

  my ($self, %args) = @_;

  my $edtr = $args{editor};
  my $hist = $args{hist};

  my $curbuf = $edtr->getcurbuf ();
  my ($row, $col) = $edtr->getcurwin ()->Cursor ();
  my ($line) = $curbuf->Get ($row);

  my ($e) = grep { ($_->[0] <= $col) && ($col < $_->[0] + $_->[1]) } $self->locations_ ($row);

  return &VIM::DoCommand (":$1") if ($e && ($e->[2] =~ m/^=(\d+)$/o));

  unless ($args{defn})
    {
      my ($word) = &vimgit::tools::findword ($col, $line);
      return $edtr->find (word => $word, hist => $hist) if ($word);
      return;
    }

  return unless ($e);

  my ($b, $len, $target, $pick) = @$e;
  my $name = substr ($line, $b, $len);

  return &VIM::Msg ("No definition for $name") unless ($target);

# several definitions : the one of the tree first, then the others

  if (my ($kind, $n) = ($pick =~ m/^(\w+):(\w+)$/o))
    {
      my $ws = $edtr->{workspace};
      $ws->refresh ();
      my @P = ($target, grep { $_ ne $target } map { "$_->{file}:$_->{line}" }
               $ws->definitions ($n, types => ($kind eq 'type')));
      $target = $edtr->pick (@P) or return;
    }

  return $edtr->edit (files => [ $target ], hist => $hist);
}

1;
