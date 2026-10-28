package vimgit::argtrace;

# :AT : the call sequences leading to a routine, for one of its dummy arguments, up to the
# declaration of the variable passed. One block per call, depth-first, numbered after its
# place in the sequences ([1.2.1]) : the file, what is passed, the CALL statement with 2
# statements before and after it, carets under the argument; a chain ends with the
# declaration of the first variable that is not a dummy argument, a module, a literal or an
# expression.
#
# [1] arpifs/phys_dmn/foo1.F90           FOO1 passes Y as X of BAR
#
#      99 | CALL ABC (Z)
#     100 | CALL BAR (Y)
#         |           ^
#
# The location of each line is in a file next to the buffer (.loc instead of .txt) : file:line,
# or =N for a line of the buffer.

use strict;

use File::Basename;
use File::Path;
use FileHandle;

use vimgit::fxparse;

use base qw (vimgit::file);

# statements shown before and after a CALL or a declaration; column of the phrases

our $CONTEXT = 2;
our $COLUMN = 40;

sub new
{
  my $class = shift;
  return bless { @_ }, $class;
}

sub filename
{
  my ($class, %args) = @_;
  my $f = "$args{editor}{TOP}/argtrace=/" . lc ("$args{routine}.$args{name}");
  $f .= '.follow' if ($args{follow});
  $f .= ".depth=$args{depth}";
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

# trace dummy argument $args{name} (or the word at the cursor) of the routine around the
# cursor; depth : levels of callers; follow : go on through the components of dummy
# arguments

  my ($class, %args) = @_;

  my $edtr  = $args{editor};
  my $ws    = $edtr->{workspace};
  my $depth = $args{depth};

  my ($ok, $err) = 'vimgit::fxparse'->available ();
  unless ($ok)
    {
      &VIM::Msg ("fxtran cannot be loaded: $err");
      return;
    }

  unless ($ws->refresh ())
    {
      &VIM::Msg ('The indexes have no call information: run vimgit -i');
      return;
    }

  my $self = bless { editor => $edtr, ws => $ws, follow => $args{follow}, depth => $depth,
                     out => [], loc => [], seen => {}, onpath => {}, blocks => 0 }, $class;

# the routine and its dummy argument

  my ($file, $line) = ($args{file}, $args{line});
  my $p = eval { 'vimgit::fxparse'->parse ($ws->realpath ($file)) };
  unless ($p)
    {
      &VIM::Msg ("$file cannot be parsed: $@");
      return;
    }

  my $u = $p->unit_at ($line);
  unless ($u)
    {
      &VIM::Msg ('The cursor is not in a subroutine or a function');
      return;
    }

  my $name = uc ($args{name});
  unless (grep { $_ eq $name } @{ $u->{dummies} })
    {
      &VIM::Msg ("$name is not a dummy argument of $u->{name}");
      return;
    }

  $self->{title} = sprintf (":AT %s in %s (%s:%d)%s, depth %d", $name, $u->{name}, $file, $u->{line},
                            ($args{follow} ? ', follow' : ''), $depth);
  $self->line_ ($self->{title}, "$file:$u->{line}");

  $self->up_ (file => $file, parse => $p, unit => $u, name => $name, number => [], level => 1);

  $self->line_ ('');
  $self->line_ ('No call found.') if ($self->{blocks} == 0);

# the buffer, and the locations of its lines

  my $filename = $class->filename (%args, routine => $u->{name}, name => $name);
  &mkpath (&dirname ($filename));

  my $fh = 'FileHandle'->new (">$filename");
  $fh->print (map { "$_\n" } @{ $self->{out} });
  $fh->close ();
  my $fl = 'FileHandle'->new ('>' . &locfile ($filename));
  $fl->print (map { (defined ($_) ? $_ : '') . "\n" } @{ $self->{loc} });
  $fl->close ();

  &VIM::DoCommand ("silent! bwipeout $filename");
  &VIM::DoCommand ("silent view $filename");
  &VIM::DoCommand ('setlocal nowrap');

  &VIM::Msg (sprintf ("%s: %d calls", $self->{title}, $self->{blocks}));

  return $class->new (file => $filename);
}

sub line_
{

# a line of the buffer, and the location <TAB> opens

  my ($self, $text, $loc) = @_;
  push @{ $self->{out} }, $text;
  push @{ $self->{loc} }, $loc;
}

sub header_
{

# the first line of a block : number, file, phrase; returns its line number in the buffer

  my ($self, $number, $file, $phrase, $loc) = @_;
  my $h = '[' . join ('.', @$number) . "] $file";
  $self->line_ ('');
  $self->line_ ($h . (' ' x (($COLUMN - length ($h) > 1) ? $COLUMN - length ($h) : 1)) . $phrase, $loc);
  return scalar (@{ $self->{out} });
}

sub show_
{

# the context of node $n (a CALL statement or a declaration) in file $file, carets under
# node $mark

  my ($self, $p, $file, $n, $mark) = @_;

  $self->line_ ('');

  my ($ml, $mc, $len) = ($mark->getAttribute ('vL'), $mark->getAttribute ('vC'));
  ($len) = map { length ($_) } split (m/\n/o, $mark->textContent);

  for my $l ($p->context ($n, $CONTEXT))
    {
      if (! defined ($l))
        {
          $self->line_ ('   ...');
          next;
        }
      my ($num, $text) = @$l;
      $self->line_ (sprintf ("%6d | %s", $num, $text), "$file:$num");
      $self->line_ (sprintf ("%6s | %s%s", '', ' ' x $mc, '^' x ($len || 1)), "$file:$num")
        if ($num == $ml);
    }
}

sub callsites_
{

# calls of unit $u (dummy argument number $pos) : [ file, parsed file, call node ] in the
# routine containing it (contained routine), or in the callers given by the index

  my ($self, $file, $p, $u) = @_;

  if (my $h = $u->{host})
    {
      return map { [ $file, $p, $_ ] } @{ $p->calls ($h, $u->{name}) };
    }

  my @r;
  my %done;
  for my $d ($self->{ws}->callers ($u->{name}))
    {
      next if ($done{"$d->{file}:$d->{line}"}++);
      my $q = eval { 'vimgit::fxparse'->parse ($self->{ws}->realpath ($d->{file})) };
      unless ($q)
        {
# fxtran fails : first line of its message, and the line of the source it shows
          my ($msg) = ($@ =~ m/^At \S+\s*\n\s*(\S.*?)\s*$/mo);
          my ($l) = ($@ =~ m/^\s*(\d+) \|/mo);
          push @r, [ $d->{file}, undef, undef, ($msg || 'fxtran failed') . ($l ? " at line $l" : ''), $d->{line} ];
          next;
        }
      my $c = $q->unit_at ($d->{line}) or next;
      push @r, map { [ $d->{file}, $q, $_ ] } @{ $q->calls ($c, $u->{name}) };
    }

  return @r;
}

sub up_
{

# the calls passing a variable as dummy argument $args{name} of unit $args{unit}, and what
# each call passes; number : number of the block of the caller; level : depth

  my ($self, %args) = @_;

  my ($file, $p, $u, $name, $level) = @args{qw (file parse unit name level)};

  my $key = "$file:$u->{line}:$name";
  local $self->{onpath}{$key} = 1;

  my $pos;
  ($pos) = grep { $u->{dummies}[$_] eq $name } (0 .. $#{ $u->{dummies} });

  my @site = $self->callsites_ ($file, $p, $u);

  if ((! @site) && @{ $args{number} })
    {
      $self->line_ ('');
      $self->line_ ('[' . join ('.', @{ $args{number} }, '*') . "] no call of $u->{name} found");
      return;
    }

  if (@site && ($level > $self->{depth}))
    {
      $self->line_ ('');
      $self->line_ (sprintf ("[%s] ... %d call%s of %s not shown (depth %d; :AT %d to go further)",
                             join ('.', @{ $args{number} }, '*'), scalar (@site), (@site > 1 ? 's' : ''),
                             $u->{name}, $self->{depth}, $self->{depth} + 5));
      return;
    }

  my $k = 0;
  for my $s (@site)
    {
      my ($cfile, $q, $call, $error, $eline) = @$s;
      my @number = (@{ $args{number} }, ++$k);
      $self->{blocks}++;

      if ($error)
        {
          $self->header_ (\@number, $cfile, "cannot be parsed by fxtran ($error); its calls of $u->{name} are not shown",
                          "$cfile:$eline");
          next;
        }

      my $c = $q->unit_of ($call);
      my $cname = $c ? $c->{name} : '?';
      my $cline = $call->getAttribute ('vL');

# a call already shown

      my $site = "$cfile:$cline:$u->{name}:$name";
      if (my $seen = $self->{seen}{$site})
        {
          $self->line_ ('');
          $self->line_ ('[' . join ('.', @number) . "] see [$seen->[0]]", "=$seen->[1]");
          next;
        }

      my ($arg, $e) = $q->actual ($call, $pos, $name);

      unless ($e)
        {
          my $l = $self->header_ (\@number, $cfile, "$cname does not pass $name to $u->{name}", "$cfile:$cline");
          $self->{seen}{$site} = [ join ('.', @number), $l ];
          my ($pd) = $q->{xpc}->findnodes ('./f:procedure-designator', $call);
          $self->show_ ($q, $cfile, $call, $pd);
          next;
        }

      my $what = $self->classify_ ($q, $c, $call, $e);

      my $phrase = "$cname passes " . $e->textContent . ($what->{via} ? " ($what->{via})" : '')
                 . " as $name of $u->{name}";
      $phrase .= ' (literal)' if ($what->{kind} eq 'literal');
      $phrase .= ' (expression)' if ($what->{kind} eq 'expression');

      my $l = $self->header_ (\@number, $cfile, $phrase, "$cfile:$cline");
      $self->{seen}{$site} = [ join ('.', @number), $l ];
      $self->show_ ($q, $cfile, $call, $arg);

      if ($what->{kind} eq 'dummy')
        {
          my $next = "$cfile:$what->{unit}{line}:$what->{name}";
          if ($self->{onpath}{$next})
            {
              $self->line_ ('');
              $self->line_ ('[' . join ('.', @number, 1) . "] $what->{name} of $what->{unit}{name}: recursive call, not followed");
              next;
            }
          $self->up_ (file => $cfile, parse => $q, unit => $what->{unit}, name => $what->{name},
                      number => \@number, level => $level + 1);
        }
      elsif ($what->{kind} eq 'leaf')
        {
          $self->leaf_ ([ @number, 1 ], $cfile, $q, $what);
        }
    }
}

sub classify_
{

# what expression $e, passed by call $call of unit $c, is : { kind => dummy (unit, name),
# leaf (phrase, node, mark), literal, expression; via : the ASSOCIATE names replaced }

  my ($self, $q, $c, $call, $e) = @_;

  my $x = $q->expression ($e);
  return { kind => $x->{kind} } unless ($x->{kind} eq 'name');

  my $base = $x->{base};
  my $component = $x->{component};
  my @via;

# ASSOCIATE names : replaced by their selectors

  my %seen;
  while (my ($a) = grep { $_->{name} eq $base } @{ $q->associates ($call) })
    {
      last if ($seen{$base}++);
      push @via, "$a->{name} => " . $a->{selector}->textContent;
      my $y = $q->expression ($a->{selector});
      return { kind => $y->{kind}, via => join (', ', @via) } unless ($y->{kind} eq 'name');
      $base = $y->{base};
      $component ||= $y->{component};
    }

  my $via = join (', ', @via);

  return { %{ $self->variable_ ($q, $c, $base, $component, ($via ? $x->{text} . " ($via)" : $x->{text})) }, via => $via };
}

sub variable_
{

# where variable $name of unit $c comes from : a dummy argument (of $c, or of its host), a
# local variable, a module; component : passed as a component of $name ($text as written)

  my ($self, $q, $c, $name, $component, $text) = @_;

  for (my $u = $c; $u; $u = $u->{host})
    {
      if (grep { $_ eq $name } @{ $u->{dummies} })
        {
          if ($component && ! $self->{follow})
            {
              my $d = $q->declaration ($u, $name);
              return { kind => 'leaf', node => ($d ? $d->{stmt} : undef), mark => ($d ? $d->{en} : undef),
                       phrase => "$text is a component of $name, dummy argument of $u->{name} (:AT follow goes on)" };
            }
          return { kind => 'dummy', unit => $u, name => $name };
        }

      if (my $d = $q->declaration ($u, $name))
        {
          my $what = $d->{attrs}{POINTER} ? 'a pointer local to' : 'local to';
          my $host = ($u == $c) ? '' : " (host of $c->{name})";
          return { kind => 'leaf', node => $d->{stmt}, mark => $d->{en}, phrase => "$name is $what $u->{name}$host" };
        }

      for my $s (@{ $q->uses ($u) })
        {
          next unless ($s->{only} && $s->{only}{$name});
          return { kind => 'leaf', node => $s->{stmt}, mark => $s->{only}{$name}, phrase => "$name comes from module $s->{module}" };
        }
    }

# the module of the routine : its variables, its USE statements

  my $m = $c->{module};
  for (my $h = $c; $h && ! $m; $h = $h->{host})
    {
      $m = $h->{module};
    }

  if ($m)
    {
      if (my $d = $q->declaration ($m, $name))
        {
          return { kind => 'leaf', node => $d->{stmt}, mark => $d->{en}, phrase => "$name is a variable of module $m->{name}" };
        }
      for my $s (@{ $q->uses ($m) })
        {
          next unless ($s->{only} && $s->{only}{$name});
          return { kind => 'leaf', node => $s->{stmt}, mark => $s->{only}{$name}, phrase => "$name comes from module $s->{module}" };
        }
    }

# USE statements without ONLY

  my @all;
  for my $u (grep { $_ } ($c, map ({ $_ } &hosts_ ($c)), $m))
    {
      push @all, grep { ! $_->{only} } @{ $q->uses ($u) };
    }

  if (@all)
    {
      my %m;
      my @mods = grep { ! $m{$_}++ } map { $_->{module} } @all;
      return { kind => 'leaf', node => $all[0]{stmt}, mark => $all[0]{stmt},
               phrase => "$name comes from one of the modules " . join (', ', @mods) };
    }

  return { kind => 'leaf', phrase => "$name is not declared in $c->{name}" };
}

sub hosts_
{
  my $u = shift;
  my @h;
  for (my $h = $u->{host}; $h; $h = $h->{host})
    {
      push @h, $h;
    }
  return @h;
}

sub leaf_
{

# the block ending a chain

  my ($self, $number, $file, $q, $what) = @_;

  my $loc = $what->{node} ? "$file:" . $what->{node}->getAttribute ('vL') : undef;
  $self->header_ ($number, $file, $what->{phrase}, $loc);
  $self->show_ ($q, $file, $what->{node}, $what->{mark}) if ($what->{node});
}

sub do_find
{

# <TAB>, ² : open the file at the location of the line; on a "see" line, go to the block

  my ($self, %args) = @_;

  my $edtr = $args{editor};
  my ($row) = $edtr->getcurwin ()->Cursor ();

  my $fh = 'FileHandle'->new ('<' . &locfile ($self->{file})) or return;
  my $loc;
  $loc = <$fh> for (1 .. $row);
  return unless (defined ($loc));
  chomp ($loc);
  return if ($loc eq '');

  return &VIM::DoCommand (":$1") if ($loc =~ m/^=(\d+)$/o);

  return $edtr->edit (files => [ $loc ], hist => $args{hist});
}

1;
