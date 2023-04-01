package vimgit::lang;

use strict;

use vimgit::lang::fortran;
use vimgit::lang::unknown;
use vimgit::lang::C;

sub lang
{
  my $class = shift;

  return 'fortran'
    if ($_[0] =~ m/\.F(?:90)?$/io);

  return 'C'
    if ($_[0] =~ m/\.(?:c|cc)$/io);

  return 'unknown';
}

sub lang2ext
{
  my ($class, $lang) = @_;

  my %lang2ext = (fortran => '.F90', C => '.c');

  return $lang2ext{$lang} || '.txt';
}

sub do_find
{
  my ($class, %args) = @_;

  my $word = $args{word};
  my $edtr = $args{editor};
  my $hist = $args{hist};

# search for word

  $edtr->find (word => $word, hist => $hist);

}

1;

