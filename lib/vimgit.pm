package vimgit;

use strict;

use File::Spec;
use File::Basename;
use File::Path;
use FileHandle;
use Data::Dumper;

use vimgit::mini;
use vimgit::lang;
use vimgit::file;
use vimgit::tools;
use vimgit::history;

sub setlog
{

# open logfile

  my $self = shift;
  my $verbose = shift;

  if ($verbose)
    {
      mkdir ($self->{TOP});
      my $fhlog = 'FileHandle'->new (">>$self->{TOP}/log");
      $fhlog->autoflush (1);
      $self->{fhlog} = $fhlog;
    }
}

sub edit
{

# edit a list of files

  my ($self, %args) = @_;

  my @HlF;

# prepare file list

  for my $F0 (@{ $args{files} })
    {
      my $F = $F0;

      my ($line, $column) = ('', '');

      if ($F =~ s/:(\d+)(?:(?:\.|:)(\d+))?$//go)
        {
          ($line, $column) = ($1, $2);
        }
      elsif ($F =~ s/\((\d+)\)(?::.*)?$//o)
        {
          ($line) = ($1);
        }

# a path to an existing file is used as is; otherwise look up the basename in the indexes;
# files of directories (dir) are named <name>/<path>, and opened by their real path

      my @P;
      my $ws = $self->{workspace};
      my $real = sub { $ws ? $ws->realpath ($_[0]) : $_[0] };

      if ((&basename ($F) ne $F) && (-f $real->($F)))
        {
          @P = ('File::Spec'->canonpath ($F));
        }
      else
        {
          $F = &basename ($F);
          my %seen;
          @P = grep { (! $seen{$_}++) && (-f $real->($_)) } $ws->paths_for_name ($F);
        }

      unless (@P)
        {
          &VIM::DoCommand ("echohl WarningMsg | echo \"`$F' was not found; skip...\" | echohl None");
          next;
        }

# several files with the same name : let the user choose

      my $P = @P > 1 ? $self->pick (@P) : $P[0];

      push @HlF, [ $P, $line, $column ]
        if ($P);

    }

# open files; vertical split

  for my $i (reverse (0 .. $#HlF))
    {
      my ($H, $line, $column) = @{ $HlF[$i] };

      my $ws = $self->{workspace};
      my $f = 'vimgit::source'->new (file => ($ws ? $ws->realpath ($H) : $H));

      $f->do_edit (line => $line, column => $column, editor => $self);

# generated files : read-only, unless the directory is listed by readwrite

      &VIM::DoCommand ('setlocal readonly') if ($ws && $ws->readonly ($H));

      if ($args{hist})
        {
          my $Flc = $H;
          $Flc .= ":$line" if ($line);
          $Flc .= ".$column" if ($column);
          $self->{history}->push ($self->getcurwin (), 'edit', %args, files => [ $Flc ]);
        }

      &VIM::DoCommand ($args{split} || 'vsplit')
        if ($i > 0);
    }


}

sub pick
{

# ask the user to choose a file among several paths

  my ($self, @P) = @_;

  my @list = ('Select file:', map { sprintf ('%d. %s', $_ + 1, $P[$_]) } (0 .. $#P));
  my $list = join (', ', map { (my $s = $_) =~ s/'/''/go; "'$s'" } @list);

  my ($ok, $i) = &VIM::Eval ("inputlist ([$list])");

  return ($ok && ($i >= 1) && ($i <= @P)) ? $P[$i-1] : undef;
}

sub EDIT
{
  my $self = shift;

  eval
    {
      return $self->edit (files => [ @_ ], hist => 1);
    };

  $self->reportbug ($@);
}

sub BT
{
  my $self = shift;

  eval
    {
      return $self->edit (files => [ @_ ], hist => 1, split => 'split');
    };

  $self->reportbug ($@);
}

sub reportbug
{
  my ($self, $e) = @_;

  $e && &VIM::Msg ("An error occurred: `$e'; please exit the editor");

}

sub getcurbuf
{

# returns VIM current buffer

  my $self = shift;
  no warnings;
  return $main::curbuf;
}

sub getcurwin
{

# returns VIM current window

  my $self = shift;
  no warnings;
  return $main::curwin;
}

sub getcurfile
{
  my $self = shift;
  no warnings;
  return 'vimgit::file'->new (file => $main::curbuf->Name ());
}

sub TRANSFORM
{
  my ($self, @args) = @_;

  eval
    {
      return $self->transform (@args);
    };

  $self->reportbug ($@);

}

sub transform
{
  my ($self, @args) = @_;

  my $file = $self->getcurfile ();

  if ($file->can ('do_transform'))
    {
      $file->do_transform (editor => $self, args => [map { split (m/\s+/o, $_) } @args]);
    }
  else
    {
      &VIM::Msg (sprintf ("`%s' do not accept transform", &basename ($file->{file})));
    }

}

sub FIND
{
  my ($self, %args) = @_;

  eval
    {

# current : search the repository of the current buffer only

      if (delete $args{current})
        {
          no warnings;
          my ($repo) = $self->{workspace}->repo_of ('File::Spec'->abs2rel ($main::curbuf->Name ()));
          unless ($repo)
            {
              &VIM::Msg ('The current buffer is not in a repository of the workspace');
              return;
            }
          $args{repo} = $repo->name ();
        }

      if ($args{new_window})
        {
          &VIM::DoCommand (':split');
        }
      return $self->find (hist => 1, %args);
    };

  $self->reportbug ($@);

}

sub find
{

# find word using index and create a listing 
# regex filters the results; if this is a single file, then we edit this file

  my ($self, %args) = @_;


  if ($args{auto})
    {
      my $file = $self->getcurfile ();
      return $file->do_find (editor => $self, %args);
    }


# the index holds words only

  unless ($args{word} =~ m/^\w+$/o)
    {
      &VIM::Msg ("`$args{word}' is not a word");
      return;
    }

  if ($args{hist})
    {
      $self->{history}->push ($self->getcurwin (), 'find', %args);
    }


  my $word  = lc ($args{word});

  my $regex = $args{regex};
  my $rank  = $args{rank} || 0;
  my $defn  = $args{defn};
  my $call  = $args{call};

  return 'vimgit::search'->create (editor => $self, word => $word, regex => $regex, 
                                   rank => $rank, defn => $defn, call => $call, repo => $args{repo});
}

sub CALLTREE
{

# :CT [name [depth]], :CTR [name [depth]] (callers => 1); without a name, the word under
# the cursor; :TT, :TTR (types => 1, users => 1) : the same for derived types

  my ($self, $argstr, %opt) = @_;

  eval
    {
      my ($word, $depth) = split (' ', $argstr || '');

      unless (defined ($word))
        {
          my ($row, $col) = $self->getcurwin ()->Cursor ();
          my ($line) = $self->getcurbuf ()->Get ($row);
          ($word) = &vimgit::tools::findword ($col, $line);
        }

      unless (defined ($word) && ($word =~ m/^\w+$/o))
        {
          &VIM::Msg (sprintf ("`%s' is not a %s name", defined ($word) ? $word : '', ($opt{types} ? 'type' : 'routine')));
          return;
        }

      if (defined ($depth) && ($depth !~ m/^\d+$/o))
        {
          &VIM::Msg ("`$depth' is not a depth");
          return;
        }

      $depth = $self->{depth} unless (defined ($depth));

      return $self->typetree (word => $word, depth => $depth, users => $opt{users}, hist => 1) if ($opt{types});
      return $self->calltree (word => $word, depth => $depth, callers => $opt{callers}, hist => 1);
    };

  $self->reportbug ($@);
}

sub ARGTRACE
{

# :AT [name] [depth] [follow] : the call sequences leading to dummy argument name (the word
# under the cursor without a name) of the routine around the cursor; the words in any order;
# :ATD [name] [depth] (down => 1) : the calls passing variable or component path name (X%Y)
# down the call tree, the path under the cursor without a name

  my ($self, $argstr, %opt) = @_;

  eval
    {
      my ($name, $depth, $follow);
      for my $w (split (' ', $argstr || ''))
        {
          if ($w =~ m/^\d+$/o)
            {
              $depth = $w;
            }
          elsif (lc ($w) eq 'follow')
            {
              $follow = 1;
            }
          else
            {
              $name = $w;
            }
        }

      my ($row, $col) = $self->getcurwin ()->Cursor ();

      unless (defined ($name))
        {
          my ($line) = $self->getcurbuf ()->Get ($row);
          ($name) = $opt{down} ? &path_at_ ($col, $line) : &vimgit::tools::findword ($col, $line);
        }

      unless (defined ($name) && ($name =~ ($opt{down} ? qr/^\w+(?:\s*%\s*\w+)*$/o : qr/^\w+$/o)))
        {
          &VIM::Msg (sprintf ("`%s' is not a %s", (defined ($name) ? $name : ''), ($opt{down} ? 'variable' : 'dummy argument name')));
          return;
        }

# the current file, as a workspace path

      no warnings;
      my $f = 'File::Spec'->canonpath ('File::Spec'->abs2rel ($main::curbuf->Name ()));
      my ($repo, $rel) = $self->{workspace}->repo_of ($f);
      unless ($repo)
        {
          &VIM::Msg ('The current buffer is not in a repository of the workspace');
          return;
        }

      return $self->argtrace (file => $repo->path ($rel), line => $row, name => $name, down => $opt{down},
                              depth => (defined ($depth) ? $depth : $self->{atdepth} || 5), follow => $follow, hist => 1);
    };

  $self->reportbug ($@);
}

sub path_at_
{

# the variable or component path at column $col of $line : on X in X%Y%Z, X; on Y, X%Y;
# subscripts left out. From the word under the cursor, leftward over % and subscripts

  my ($col, $line) = @_;

  my ($b, $w);
  while ($line =~ m/(\w+)/g)
    {
      ($b, $w) = ($-[1], $1) if (($-[1] <= $col) && ($col < $+[1]));
    }
  return undef unless (defined ($w));

  my @p = ($w);
  my $j = $b - 1;
  while (1)
    {
      $j-- while (($j >= 0) && (substr ($line, $j, 1) eq ' '));
      last unless (($j >= 0) && (substr ($line, $j, 1) eq '%'));
      $j--;
      $j-- while (($j >= 0) && (substr ($line, $j, 1) eq ' '));
# a subscript : back to its opening parenthesis
      if (($j >= 0) && (substr ($line, $j, 1) eq ')'))
        {
          my $depth = 0;
          for (; $j >= 0; $j--)
            {
              my $ch = substr ($line, $j, 1);
              $depth++ if ($ch eq ')');
              $depth-- if ($ch eq '(');
              last if ($depth == 0);
            }
          $j--;
          $j-- while (($j >= 0) && (substr ($line, $j, 1) eq ' '));
        }
      my $e = $j + 1;
      $j-- while (($j >= 0) && (substr ($line, $j, 1) =~ m/\w/o));
      last if ($j + 1 == $e);
      unshift @p, substr ($line, $j + 1, $e - $j - 1);
    }

  return join ('%', @p);
}

sub argtrace
{
  my ($self, %args) = @_;

  $self->{history}->push ($self->getcurwin (), 'argtrace', %args)
    if ($args{hist});

  use vimgit::argtrace;
  return 'vimgit::argtrace'->create (editor => $self, %args);
}

sub CONFIG
{

# :CONFIG : the settings in use, and where they come from

  my $self = shift;

  eval
    {
      my $f = "$self->{TOP}/tmp=/config.txt";
      my $fh = 'FileHandle'->new (">$f") or die ("Cannot write $f");
      $fh->print ("# vimgit settings for $self->{ROOT}\n", $self->{workspace}{config}->text ());
      $fh->print ("# warning: $_\n") for (@{ $self->{workspace}{warnings} });
      $fh->close ();
      $self->edit (files => [ $f ], hist => 1);
    };

  $self->reportbug ($@);
}

sub calltree
{
  my ($self, %args) = @_;

  $self->{history}->push ($self->getcurwin (), 'calltree', %args)
    if ($args{hist});

  use vimgit::calltree;
  return 'vimgit::calltree'->create (editor => $self, %args);
}

sub typetree
{
  my ($self, %args) = @_;

  $self->{history}->push ($self->getcurwin (), 'typetree', %args)
    if ($args{hist});

  use vimgit::typetree;
  return 'vimgit::typetree'->create (editor => $self, %args);
}

sub definition
{

# definition of routine $args{word} (CALL x, #include "x.intfb.h"), or of derived type
# $args{word} (types : TYPE (x), CLASS (x)), from the definitions of the indexes; a pick list
# when there are several, the most likely first; without this information in the indexes, a
# search for the definition ($args{regex})

  my ($self, %args) = @_;

  my $ws = $self->{workspace};
  my $word = lc ($args{word});

  my @d;

  if ($ws->refresh (types => $args{types}))
    {

# the caller : the current file

      no warnings;
      my $f = 'File::Spec'->canonpath ('File::Spec'->abs2rel ($main::curbuf->Name ()));
      my ($repo, $rel) = $ws->repo_of ($f);
# the workspace path : <name>/<path> for the files of a directory (dir)
      $f = $repo->path ($rel) if ($repo);
      @d = $ws->definitions ($word, types => $args{types}, ($repo ? (caller => { file => $f, repo => $repo }) : ()));
    }

  return $self->find (word => $word, defn => 1, regex => $args{regex}, hist => 1, lang => 'fortran')
    unless (@d);

  my @P = map { "$_->{file}:$_->{line}" } @d;
  my $P = (@P > 1) ? $self->pick (@P) : $P[0];

  return $P ? $self->edit (files => [ $P ], hist => 1) : undef;
}

sub BACK
{
  my $self = shift;

  eval
    {

      my $curwin = $self->getcurwin ();
     
     
      my ($method0, %args0) = $self->{history}->pop ($curwin);
      my ($method1, %args1) = $self->{history}->pop ($curwin);
     
     
      if ($method1) 
        {
          my $fhlog = $self->{fhlog};
          $fhlog && $fhlog->print (&Dumper ([$method1, \%args1]));
          return $self->$method1 (%args1);
        }
      else
        {
          &VIM::Msg (' ');
        }

    };

  $self->reportbug ($@);

}

sub LOGHIST
{
  my $self = shift;
  my $fhlog = $self->{fhlog};
  $fhlog && $self->{history}->log ($fhlog);
}

sub COMMIT
{
  my ($self, %args) = @_;

  if (my $file = $self->getcurfile ())
    {
      $file->singleLink ();
    }
 
}

sub UPDATE
{

# a file was written : scan it again, unless it is outside the repositories, 
# in .vimgit, or ignored by git

  my $self = shift;

  eval
    {
      no warnings;
      my $f = 'File::Spec'->abs2rel ($main::curbuf->Name ());

      return if ($f =~ m/\.vimgit\b/o);

      my ($repo, $rel) = $self->{workspace}->repo_of ($f);

      $repo && $repo->update ($rel);
    };

  $self->reportbug ($@);
}

sub REFRESH
{

# :R; forget everything, files are scanned again at the next search

  my $self = shift;

  $_->drop () for ($self->{workspace}->repos ());

  &VIM::Msg ('vimgit: cache dropped');
}

1;
