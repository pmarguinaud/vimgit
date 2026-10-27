package vimgit::calltree;

# call tree buffers : a routine and the routines it calls (:CT), or the routines calling it
# (:CTR), drawn by vimgit::tree; callers are on the left of the routines they call

use strict;

use base qw (vimgit::tree);

sub filename
{
  my ($class, %args) = @_;
  my $f = "$args{editor}{TOP}/calltree=/" . lc ($args{word});
  $f .= '.callers' if ($args{callers});
  $f .= ".depth=$args{depth}" if (defined ($args{depth}));
  return "$f.txt";
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

# first : definition -> node where it is expanded; onpath : definitions being expanded
# (recursion)

  my (%first, %onpath);

  my $walk;
  $walk = sub
  {
    no warnings 'recursion';

    my ($d, $level, $others) = @_;

    my $loc = "$d->{file}:$d->{line}";

    if (my $n = $first{$d->{key}})
      {
        return { parts => [ [ uc ($d->{name}), $loc ] ], see => $n, recursive => $onpath{$d->{key}} };
      }

    my $node = { parts => [ [ uc ($d->{name}), $loc, ($others ? "routine:$d->{name}" : '') ] ],
                 note => ($others ? "[+$others]" : ''), kids => [] };
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
                push @{ $node->{kids} }, { parts => [ [ uc ($name), '' ] ], note => '(type-bound)' };
                next;
              }
            my @d = $ws->definitions ($name, caller => $d);
            unless (@d)
              {
                push @{ $node->{kids} }, { parts => [ [ uc ($name), '' ] ], note => '(not found)' };
                next;
              }
            push @{ $node->{kids} }, $walk->($d[0], $level + 1, scalar (@d) - 1);
          }
      }

    delete $onpath{$d->{key}};

    return $node;
  };

  my $root = $walk->($root[0], 0, scalar (@root) - 1);

  my $filename = $class->filename (%args);
  my $nrow = $class->draw (root => $root, filename => $filename, mirror => $callers);

  &VIM::Msg (sprintf ("%s %s: %d lines, %d routines", ($callers ? 'Callers of' : 'Call tree of'), uc ($word),
                      $nrow, scalar (keys (%first))));

  return $class->new (file => $filename);
}

1;
