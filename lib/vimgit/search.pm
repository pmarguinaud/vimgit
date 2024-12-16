package vimgit::search;

use strict;

use File::Basename;
use List::Util qw (min max);
use File::Path;
use Data::Dumper;

use base qw (vimgit::file);

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

  my @WwfINDEX = $edtr->getwindex ();

  my @f;
 
  while (my ($TOP, $WINDEX, $windex, $findex) = splice (@WwfINDEX, 0, 4))
    {
      push @f,
          (split (m/\s+/o, $windex->{$word}), 
           grep ({ ! $findex->{$_} } split (m/\s+/o, $WINDEX->{$word})));
    }

  my %f = map { ($_, 1) } @f;
  @f = sort keys (%f);
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

  &mkpath ("$edtr->{ROOT}/search=");

  my $curbuf = $edtr->getcurbuf ();
  my $lang   = 'vimgit::lang'->lang ($curbuf->Name ());

  my $files = $class->getfiles (word => $word, editor => $edtr);

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

  my $filename = "$edtr->{ROOT}/search=/word=$word.rank=$rank$ext";
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

  &VIM::DoCommand (':redraw!');

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
  
  my $filename = "$edtr->{ROOT}/search=/call.word=$word.rank=$rank$ext";
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
  
  my $filename = "$edtr->{ROOT}/search=/defn.word=$word.rank=$rank$ext";
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

  unless (grep { $fl1->[0][0] != $_->[0] } @$fl1)
    {

# a single file was matched; change to this file

      my ($f, $l) = @{ $fl1->[0] };

      $edtr->edit (files => [ &basename ($f) . ":$l" ], hist => 0);

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

  if ($line =~ m/^\S+\.F(?:90)?(?::\d+)?$/io)
    {

# search file

      my $filename_line = &basename ($line);
      return $edtr->edit (files => [ $filename_line ], hist => $hist);
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
              if ($line =~ m/^(\S+\.F(?:90)?)(?::\d+)?$/io)
                {
                  my $filename = &basename ($1);
                  my $filename_line = "$filename:$ln";
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

  for my $f (@{ $args{files} })
    {
      next unless (my $fhF = 'FileHandle'->new ("<$f"));
      my @text = <$fhF>;
      $fhF->close ();
  
# number of lines before/after match
      my $width = 2;
 
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
