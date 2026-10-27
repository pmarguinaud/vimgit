package vimgit::typetree;

# type tree buffers : a derived type and the types of its components (:TT), or the types
# using it (:TTR), drawn by vimgit::tree :
#
#          ┌── TYPE, EXTENDS (TPARENT)
#          │
# TCHILD ──┼── TYPE (TCST), POINTER :: YRCST
#          │
#          └── TYPE (TGEO) :: YRGEO (see line 12)
#
# types using a type are on its left, as MODEL%YRCST, or TCHILD (extends)

use strict;

use base qw (vimgit::tree);

sub filename
{
  my ($class, %args) = @_;
  my $f = "$args{editor}{TOP}/typetree=/" . lc ($args{word});
  $f .= '.users' if ($args{users});
  $f .= ".depth=$args{depth}" if (defined ($args{depth}));
  return "$f.txt";
}

sub create
{

# build the tree of type $args{word}, write it, open it; depth : levels shown below the type;
# users : types using it instead of the types of its components

  my ($class, %args) = @_;

  my $edtr  = $args{editor};
  my $ws    = $edtr->{workspace};
  my $word  = lc ($args{word});
  my $depth = $args{depth};
  my $users = $args{users};

  unless ($ws->refresh (types => 1))
    {
      &VIM::Msg ('The indexes have no type information: run vimgit -i');
      return;
    }

  my @root = $ws->definitions ($word, types => 1);

  unless (@root)
    {
      &VIM::Msg ("`$word' type definition was not found");
      return;
    }

# first : definition -> node where it is expanded; onpath : definitions being expanded
# (recursion)

  my (%first, %onpath);

# expand node $node, of type definition $d, at depth $level

  my $expand;
  $expand = sub
  {
    no warnings 'recursion';

    my ($node, $d, $level) = @_;

    if (my $n = $first{$d->{key}})
      {
        @$node{qw (see recursive)} = ($n, $onpath{$d->{key}});
        return $node;
      }

    $first{$d->{key}} = $node;

    my @child = $users ? $ws->users ($d->{name}) : $ws->components ($d);

# users of another type of the same name left out : the type of their component must be
# this definition

    @child = grep { my ($t) = $ws->definitions ($d->{name}, types => 1, caller => $_->{def}); $t && ($t->{repo} == $d->{repo}) && ($t->{key} eq $d->{key}) } @child
      if ($users);

    if (defined ($depth) && ($level >= $depth))
      {
        $node->{note} = join (' ', grep { $_ } $node->{note}, '...') if (@child);
        return $node;
      }

    $onpath{$d->{key}} = 1;
    $node->{kids} = [];

    for my $c (@child)
      {
        if ($users)
          {
# the type using it : TYPE%COMPONENT, or TYPE (extends)
            my $u = $c->{def};
            my $loc = "$u->{file}:$u->{line}";
            my $kid;
            if (defined ($c->{component}))
              {
                my ($k) = grep { $_->{name} eq $c->{component} } $ws->components ($u);
                $kid = { parts => [ [ uc ($u->{name}), $loc ], [ '%' ],
                                    [ uc ($c->{component}), ($k ? "$k->{file}:$k->{line}" : $loc) ] ] };
              }
            else
              {
                $kid = { parts => [ [ uc ($u->{name}), $loc ] ], note => '(extends)' };
              }
            push @{ $node->{kids} }, $expand->($kid, $u, $level + 1);
            next;
          }

# a component : TYPE (TT), POINTER :: MM, or the parent type : TYPE, EXTENDS (TPARENT)

        my @d = $ws->definitions ($c->{type}, types => 1, caller => $d);
        my $tloc = @d ? "$d[0]{file}:$d[0]{line}" : '';
        my $kid;
        if ($c->{kind} eq 'extends')
          {
            $kid = { parts => [ [ 'TYPE, EXTENDS (' ], [ uc ($c->{type}), $tloc, (@d > 1 ? "type:$c->{type}" : '') ], [ ')' ] ] };
          }
        else
          {
            $kid = { parts => [ [ uc ($c->{kind}) . ' (' ], [ uc ($c->{type}), $tloc, (@d > 1 ? "type:$c->{type}" : '') ],
                                [ ')' . ($c->{attr} ? ', ' . uc ($c->{attr}) : '') . ' :: ' ],
                                [ uc ($c->{name}), "$c->{file}:$c->{line}" ] ] };
          }
        $kid->{note} = (@d > 1) ? '[+' . (@d - 1) . ']' : @d ? '' : '(not found)';
        push @{ $node->{kids} }, (@d ? $expand->($kid, $d[0], $level + 1) : $kid);
      }

    delete $onpath{$d->{key}};

    return $node;
  };

  my $d = $root[0];
  my $root = { parts => [ [ uc ($d->{name}), "$d->{file}:$d->{line}", (@root > 1 ? "type:$d->{name}" : '') ] ],
               note => (@root > 1 ? '[+' . (@root - 1) . ']' : '') };
  $expand->($root, $d, 0);

  my $filename = $class->filename (%args);
  my $nrow = $class->draw (root => $root, filename => $filename, mirror => $users);

  &VIM::Msg (sprintf ("%s %s: %d lines, %d types", ($users ? 'Types using' : 'Type tree of'), uc ($word),
                      $nrow, scalar (keys (%first))));

  return $class->new (file => $filename);
}

1;
