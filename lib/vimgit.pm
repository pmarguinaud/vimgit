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
      my $fhlog = 'FileHandle'->new (">>$self->{HOME}/vimgit.log");
      $fhlog->autoflush (1);
      $self->{fhlog} = $fhlog;
    }
}

sub getsindex
{
# get file location index; local index is built on the fly

  my ($self, @args) = @_;

  my %args = map { ($_, 1) } @args;

  my %hash;
      
  for my $TOP (@{ $self->{TOP} })
    {
       my $hashlist = 'vimgit::git'->getHashList (repo => $TOP);

       my $hash = (sub
       {
         my $hash;
         for $hash (@$hashlist)
           {
             my $f = "$TOP/.vimgit/$hash/sindex.db";
             return $hash if (-f $f);
           }
       })->();
      
       $hash or die ("No index was found in $TOP");

       $hash{$TOP} = $hash;
    }

  my @i;

  for my $TOP (@{ $self->{TOP} })
    {
      my $hash = $hash{$TOP};
     
      my $m = 'vimgit::git'->getDiff (repo => $TOP, hash => $hash);
     
      if ($args{sindex})
        {
          my %s;
          my %sindex;
     
          while (my ($f, $m) = each (%$m))
            {
              if (($m eq '+') || ($m eq 'M'))
                {
                  &wanted_windex_ (sindex => \%s, fhlog => $self->{fhlog}, 
                                   file => "$TOP/$f", top => $TOP, 
                                   excl => $self->{EXCL});
                }
            }
     
          &cidx (\%s, \%sindex);
     
          push @i, $TOP, \%sindex;
        }
    }
      
  if ($args{SINDEX})
    {
      unless ($self->{SINDEX})
        {
          for my $TOP (@{ $self->{TOP} })
            {
              my $hash = $hash{$TOP};
              my %SINDEX;
              tie (%SINDEX,  'DB_File', "$TOP/.vimgit/$hash/sindex.db", O_RDONLY);
              push @{ $self->{SINDEX} }, $TOP, \%SINDEX;
            }
         }
      push @i, @{ $self->{SINDEX} };
    }

  return @i;
}

sub getwindex
{
  my ($self, @args) = @_;

  my %hash;
      
  for my $TOP (@{ $self->{TOP} })
    {
       my $hashlist = 'vimgit::git'->getHashList (repo => $TOP);

       my $hash = (sub
       {
         my $hash;
         for $hash (@$hashlist)
           {
             my $f = "$TOP/.vimgit/$hash/sindex.db";
             return $hash if (-f $f);
           }
       })->();
      
       $hash or die ("No index was found in $TOP");

       $hash{$TOP} = $hash;
    }

  my @i;

  for my $TOP (@{ $self->{TOP} })
    {
      my $hash = $hash{$TOP};

      my $m = 'vimgit::git'->getDiff (repo => $TOP, hash => $hash);

      my %WINDEX;
      my %windex;
      my %findex;

      tie (%WINDEX,  'DB_File', "$TOP/.vimgit/$hash/windex.db", O_RDONLY);
      
      {
        my %b;
        while (my ($f, $m) = each (%$m))
          {
            if (($m eq '+') || ($m eq 'M'))
              {
                &wanted_windex_ (windex => \%b, findex => \%findex, 
                                 file => $f, fhlog => $self->{fhlog}, 
                                 top => $TOP, excl => $self->{EXCL});
              }
          }

        &cidx (\%b, \%windex);
      }

      push @i, ($TOP, \%WINDEX, \%windex, \%findex);
    }

  return @i;
}

sub edit
{

# edit a list of files

  my ($self, %args) = @_;

  my %sindex = $self->getsindex (qw (sindex SINDEX));

  my @HlF;

# prepare file list

  for my $F (@{ $args{files} })
    {
      my ($line, $column) = ('', '');

      my $Q = 'File::Spec'->canonpath (&dirname ($F));
      $Q = $Q eq '.' ? '' : $Q;

      $F = &basename ($F);

      if ($F =~ s/:(\d+)(?:(?:\.|:)(\d+))?$//go)
        {
          ($line, $column) = ($1, $2);
        }
      elsif ($F =~ s/\((\d+)\)(?::.*)?$//o)
        {
          ($line) = ($1);
        }
  
      my $P;

      for my $TOP (@{ $self->{TOP} })
        {
          if ($P = $sindex{$TOP}{$F})
	    {
              $P = "$TOP/$P";
              if (-f $P)
                {
                  push @HlF, [ $P, $line, $column, $F ];
                }
              last;
            }
        }

      unless ($P)
        {
          &VIM::DoCommand ("echohl WarningMsg | echo \"`$F' was not found; skip...\" | echohl None");
          next;
        }
      
      
    }

# open files; vertical split

  for my $i (reverse (0 .. $#HlF))
    {
      my ($H, $line, $column, $F) = @{ $HlF[$i] };

      my $f = 'vimgit::source'->new (file => $H);

      $f->do_edit (line => $line, column => $column, editor => $self);

      if ($args{hist})
        {
          my $Flc = $F;
          $Flc .= ":$line" if ($line);
          $Flc .= ".$column" if ($column);
          $self->{history}->push ($self->getcurwin (), 'edit', %args, files => [ $Flc ]);
        }

      &VIM::DoCommand ($args{split} || 'vsplit')
        if ($i > 0);
    }

  
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

1;

