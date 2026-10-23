package vimgit;

use strict;

use DB_File;
use Fcntl qw (O_RDONLY);

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

sub getindexhash
{

# most recent of the last commits having an index

  my $self = shift;

  my $hashlist = 'vimgit::git'->getHashList (top => $self->{REPO});

  for my $hash (@$hashlist)
    {
      return $hash if (-f "$self->{IDX}/$hash/sindex.db");
    }

  die ("No index was found; run vimgit -i");
}

sub cache
{

# session cache : indexed commit, stored indexes, and files changed since that commit,
# scanned once; dropped when HEAD moves or on :R, updated when a file is written

  my $self = shift;

  my $head = 'vimgit::git'->getHead (top => $self->{REPO});

  delete $self->{cache}
    if ($self->{cache} && ($self->{cache}{head} ne $head));

  return $self->{cache} if ($self->{cache});

  my $hash = $self->getindexhash ();

  tie (my %WINDEX, 'DB_File', "$self->{IDX}/$hash/windex.db", O_RDONLY);
  tie (my %SINDEX, 'DB_File', "$self->{IDX}/$hash/sindex.db", O_RDONLY);

# windex : word -> { file }; sindex : basename -> { file }; 
# findex : files whose stored entries are obsolete; wordsof : file -> words found in it

  my $c = $self->{cache} = { head => $head, hash => $hash, WINDEX => \%WINDEX, SINDEX => \%SINDEX, 
                             windex => {}, sindex => {}, findex => {}, wordsof => {} };

  my $m = 'vimgit::git'->getDiff (top => $self->{REPO}, hash => $hash);

  for my $f (keys (%$m))
    {
      $c->{findex}{$f} = 1;
      $self->scan ($f) if (($m->{$f} eq '+') || ($m->{$f} eq 'M'));
    }

  return $c;
}

sub scan
{

# forget what is known about file $f, then scan it again

  my ($self, $f) = @_;

  my $c = $self->{cache};

  for my $w (@{ delete $c->{wordsof}{$f} || [] })
    {
      delete $c->{windex}{$w}{$f};
    }
  delete $c->{sindex}{&basename ($f)}{$f};

  $c->{findex}{$f} = 1;

  my (%w, %s);
  &wanted_windex_ (windex => \%w, sindex => \%s, fhlog => $self->{fhlog}, file => $f);

  for my $w (keys (%w))
    {
      $c->{windex}{$w}{$f} = 1;
      push @{ $c->{wordsof}{$f} }, $w;
    }
  for my $b (keys (%s))
    {
      $c->{sindex}{$b}{$f} = 1;
    }
}

sub getsindex
{

# file location indexes : changed files (basename -> { file }), stored index (basename -> "file file ...")

  my $self = shift;
  my $c = $self->cache ();
  return ($c->{sindex}, $c->{SINDEX});
}

sub getwindex
{

# word indexes : changed files (word -> { file }), stored index (word -> "file file ..."), 
# and the files whose stored entries are obsolete

  my $self = shift;
  my $c = $self->cache ();
  return ($c->{WINDEX}, $c->{windex}, $c->{findex});
}

sub edit
{

# edit a list of files

  my ($self, %args) = @_;

  my ($sindex, $SINDEX) = $self->getsindex ();

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

# a path to an existing file is used as is; otherwise look up the basename in the indexes

      my @P;

      if ((&basename ($F) ne $F) && (-f $F))
        {
          @P = ('File::Spec'->canonpath ($F));
        }
      else
        {
          $F = &basename ($F);
          my %seen;
          @P = grep { (! $seen{$_}++) && (-f $_) }
               (keys (%{ $sindex->{$F} || {} }), split (m/\s+/o, $SINDEX->{$F} || ''));
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

      my $f = 'vimgit::source'->new (file => $H);

      $f->do_edit (line => $line, column => $column, editor => $self);

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
                                   rank => $rank, defn => $defn, call => $call);
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

# a file was written : scan it again, unless it is outside the repository, 
# in .vimgit, or ignored by git

  my $self = shift;

  eval
    {
      return unless ($self->{cache});

      no warnings;
      my $f = 'File::Spec'->abs2rel ($main::curbuf->Name ());

      return if ($f =~ m,^\.\./,o);
      return if ($f =~ m/\.vimgit\b/o);
      return if ('vimgit::git'->isIgnored (top => $self->{REPO}, file => $f));

      $self->scan ($f);
    };

  $self->reportbug ($@);
}

sub REFRESH
{

# :R; forget everything, files are scanned again at the next search

  my $self = shift;

  delete $self->{cache};

  &VIM::Msg ('vimgit: cache dropped');
}

1;
