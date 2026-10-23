package vimgit::search;

use strict;

use File::Basename;
use List::Util qw (min max);
use File::Path;
use Data::Dumper;

use base qw (vimgit::file);

# above $GITGREP files, results are produced by git; $WIDTH lines around each match

our $GITGREP = 200;
our $WIDTH = 2;

sub new
{
  my $class = shift;

  my $self = bless { @_ }, $class;

  if ($self->{file})
    {
      ($self->{word}, $self->{rank}) = ($self->{file} =~ m/word=(\w+).*rank=(\d+)/o);
      $self->{lang} = 'vimgit::lang'->lang ($self->{file});
    }
  else
    {
      $self = $class->create (@_);
    }

  return $self;
}

sub getfiles
{
  my ($class, %args) = @_;
  
  my $word = $args{word};
  my $edtr = $args{editor};

# repositories in config order, files sorted in each

  my @f = $edtr->{workspace}->files_for_word ($word, repo => $args{repo});

  return \@f;
}
  
sub create
{
  my ($class, %args) = @_;

  my $word  = $args{word};
  my $rank  = $args{rank};
  my $edtr  = $args{editor};
  my $defn  = $args{defn};  # search for definition
  my $call  = $args{call};  # search for backtrace

  &mkpath ("$edtr->{TOP}/search=");

  my $curbuf = $edtr->getcurbuf ();
  my $lang   = 'vimgit::lang'->lang ($curbuf->Name ());

  my $files = $class->getfiles (word => $word, editor => $edtr, repo => $args{repo});
  
# @f = @f[$rank .. $rank + $self->{maxfind}];

  unless (@$files) 
    {
      &VIM::Msg ("`$word' was not found");
      return;
    }

  if ($defn)
    {
      return $class->create_defn (%args, lang => $lang, files => $files);
    }
  elsif ($call)
    {
      return $class->create_call (%args, lang => $lang, files => $files);
    }

# default search

  my $ext = 'vimgit::lang'->lang2ext ($lang);

  my $filename = "$edtr->{TOP}/search=/word=$word.rank=$rank$ext";
  my $fh = 'FileHandle'->new (">$filename");
  

  my ($TEXT, $fl1) = $class->pretty_grep (word => $word, editor => $edtr, files => $files);

  $fh->print (join ('', @$TEXT));

  $fh->close ();
  
  my $self = $class->new (file => $filename);

  if (@$fl1 > 0)
    {

# open result file

      &VIM::DoCommand ("silent view $filename");

# make a search to highlight word
      &VIM::DoCommand ("/\\c\\<$word\\>");

      &VIM::Msg (sprintf ("`%s' was found in %d files", $word, scalar (@$files)));


    }

  return $self;
}

sub create_call
{
  my ($class, %args) = @_;

  my $lang  = $args{lang};
  my $edtr  = $args{editor};
  my $word  = $args{word};
  my $rank  = $args{rank};
  my $files = $args{files};
  my $regex = $args{regex};


  my $ext = 'vimgit::lang'->lang2ext ($lang);
  
  my $filename = "$edtr->{TOP}/search=/call.word=$word.rank=$rank$ext";
  my $fh = 'FileHandle'->new (">$filename");
  

  my ($TEXT, $fl1) = $class->pretty_grep (word => $word, regex => $regex, 
                                          editor => $edtr, files => $files);

  $fh->print (join ('', @$TEXT));

  $fh->close ();
  
  if (@$fl1 > 0)
    {

# open result file

      &VIM::DoCommand ("silent view $filename");

# make a search to highlight word
      &VIM::DoCommand ("/\\c\\<$word\\>");

      &VIM::Msg (sprintf ("`%s' was found in %d files", $word, scalar (@$files)));


    }

  return $class->new (file => $filename);
}

sub create_defn
{
  my ($class, %args) = @_;

  my $lang  = $args{lang};
  my $edtr  = $args{editor};
  my $word  = $args{word};
  my $rank  = $args{rank};
  my $files = $args{files};
  my $regex = $args{regex};

  my $ext = 'vimgit::lang'->lang2ext ($lang);
  
  my $filename = "$edtr->{TOP}/search=/defn.word=$word.rank=$rank$ext";
  my $fh = 'FileHandle'->new (">$filename");

  my ($TEXT, $fl1) = $class->pretty_grep (word => $word, regex => $regex, 
                                          editor => $edtr, files => $files);

  $fh->print (join ('', @$TEXT));

  $fh->close ();
  
  if (@$fl1 > 0)
    {

# open result file

      &VIM::DoCommand ("silent view $filename");

# make a search to highlight word
      &VIM::DoCommand ("/\\c\\<$word\\>");

      &VIM::Msg (sprintf ("`%s' was found in %d files", $word, scalar (@$files)));


    }
  else
    {
      &VIM::Msg ("`$word' definition was not found");
      return undef;
    }

  unless (grep { $fl1->[0][0] ne $_->[0] } @$fl1)
    {

# a single file was matched; change to this file

      my ($f, $l) = @{ $fl1->[0] };

      $edtr->edit (files => [ "$f:$l" ], hist => 0);

    }

  return $class->new (file => $filename);
}

sub do_find
{

  my ($self, %args) = @_;

  my $edtr = $args{editor};
  my $hist = $args{hist};

  my $curbuf = $edtr->getcurbuf ();
  my $curwin = $edtr->getcurwin ();

  my ($row, $col) = $curwin->Cursor ();
  
  my ($line) = $curbuf->Get ($row);

# a file line : path of an indexed file, maybe followed by :line

  my $isfile = sub { my ($f) = ($_[0] =~ m/^(\S+?)(?::\d+)?$/o); return ($f && ($f =~ 'vimgit::lang'->indexed ())) ? $f : undef };

  if ($isfile->($line))
    {

# search file

      return $edtr->edit (files => [ $line ], hist => $hist);
    }

  if ($line =~ m/^(\s*)(\d+)(\s*)\|/io)
    {

# we are in a search file; see if cursor is over a line number

      my ($s1, $ln, $s2) = ($1, $2, $3);
      if ($col < length ($s1) + length ($ln) + length ($s2)) 
        {
# seek back to find filename
          while ($row > 0)
            {
              $line = $curbuf->Get ($row);
              if (my $f = $isfile->($line))
                {
                  my $filename_line = "$f:$ln";
                  return $edtr->edit (files => [ $filename_line ], hist => $hist);
                }
              $row--;
            }
        }
    }
  elsif ($line =~ m/^<<<<\s*>>>>$/o)
    {
      my ($word, $rank) = ($self->{word}, $self->{rank});
      $rank += $edtr->{maxfind};
      return $edtr->find (word => $word, rank => $rank, hist => $hist);
    }

  $self->vimgit::source::do_find (%args);
}
  

sub pretty_grep
{
  my ($class, %args) = @_;

  my $word  = $args{word};
  my $regex = $args{regex};
  my $edtr  = $args{editor};

  my (@TEXT, @fl1);

# many files : git reads them, several processes in parallel

  if ((@{ $args{files} } > $GITGREP) && (! $args{nogit}))
    {
      my $sets = $edtr->{workspace}->sets (@{ $args{files} });

      if ($regex)
        {

# keep the files where a line matches the regex, then format them below

          my $hit = 'vimgit::git'->grepFiles (sets => $sets, word => $word, context => 0);
          my @f = grep { my $f = $_; grep { $_->[1] =~ $regex } @{ $hit->{$f} || [] } } @{ $args{files} };
          return $class->pretty_grep (%args, files => \@f, nogit => 1);
        }

      my $hit = 'vimgit::git'->grepFiles (sets => $sets, word => $word, context => $WIDTH);

      for my $f (@{ $args{files} })
        {
          my $h = $hit->{$f} or next;

          my $TEXT = "\n$f\n\n";
          my $prev;

          for (@$h)
            {
              my ($n, $text) = @$_;
              $TEXT .= "...\n" if (defined ($prev) && ($n > $prev + 1));
              $TEXT .= sprintf ("%6d | %s", $n, $text);
              $prev = $n;
            }

          push @TEXT, $TEXT;
          push @fl1, [ $f, $h->[0][0] ];
        }

      return (\@TEXT, \@fl1);
    }

  for my $f (@{ $args{files} })
    {
      next unless (my $fhF = 'FileHandle'->new ("<$f"));
      my @text = <$fhF>;
      $fhF->close ();
  
# number of lines before/after match
      my $width = $WIDTH;
 
# have we printed something for this file ?
      my $pr = 0;

      my $k = -1;
      for (my $i = 0; $i <= $#text; $i++)
        {
# tests
          my $t1 = $text[$i] =~ m/\b$word\b/i;
          my $t2 = (! $regex) || ($text[$i] =~ $regex);

          if ($t1 && $t2)
            {
              my $TEXT = '';

# line window
              my $j1 = &max ($k+1, $i-$width);
              my $j2 = &min ($#text, $i+$width);


              if ($pr++)
                {
                  $TEXT .= $j1 > $k+1 ? "...\n" : '';
                }
              else
                {
                  $TEXT .= "\n$f\n\n";
                }

# before
              for (my $j = $j1; $j <= $i; $j++)
                {
                  $TEXT .= sprintf ("%6d | %s", $j+1, $text[$j]);
                }

# after; see if we match some more lines and push the window ahead
              for (my $j = $i+1; $j <= $j2; $j++)
                {
                  $TEXT .= sprintf ("%6d | %s", $j+1, $text[$j]);
                  if ($text[$j] =~ m/\b$word\b/i)
                    {
                      $j2 = &min ($#text, $j+$width);
                    }
                }

              push @fl1, [ $f, $i+1 ];
              push @TEXT, $TEXT;

              $k = $i = $j2;
            }
        }

    }

  return (\@TEXT, \@fl1);
}

1;
