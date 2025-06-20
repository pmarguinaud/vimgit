package vimgit::lang::fortran::transform::align_args;

use strict;
use base qw (vimgit::lang::fortran::transform);
use Fxtran;
use List::MoreUtils qw (uniq);
use List::Util qw (min max);

use Data::Dumper;

sub apply
{
  my ($class, %args) = @_;
  
  my $edtr = $args{editor};
  my $buf = $edtr->getcurbuf ();
  my $win = $edtr->getcurwin ();

  my $dom = $class->xml_parse (editor => $edtr, buffer => $buf, file => $args{file});

  return unless ($dom);

  my ($row, $col) = $win->Cursor ();

  my @decl = &F ('.//T-decl-stmt[.//attribute-N[string(.)="INTENT"]', $dom);
  
  my %len;
  my %att;
  
  for my $decl (@decl)
    {
      my ($tspec) = &F ('./_T-spec_', $decl, 1); $tspec =~ s/\s+//go;
  
      $len{type} = &max ($len{type} || 0, length ($tspec));
  
      my @attr = &F ('.//attribute', $decl);
      for my $attr (@attr)
        {
          my ($N) = &F ('./attribute-N', $attr, 1);
          $attr = $attr->textContent; $attr =~ s/\s+//go;
          $att{$N} = 1;
          $len{$N} = &max (($len{$N} || 0), length ($attr));
        }
    }
  
  
  my @att = sort keys (%att);
  
  for (values (%len))
    {
      $_++;
    }
  
  for my $decl (@decl)
    {
      my ($tspec) = &F ('./_T-spec_', $decl, 1); $tspec =~ s/\s+//go;
      my ($endlt) = &F ('./EN-decl-LT', $decl, 1);
  
      my @attr = &F ('.//attribute', $decl);
      my %attr = map { my ($N) = &F ('./attribute-N', $_, 1); ($N, $_->textContent) } @attr;
  
      for (values (%attr))
        {
          s/\s+//go;
        }
  
      my $code = sprintf ("%-$len{type}s", $tspec);
  
      for my $att (@att)
        {
          if ($attr{$att})
            {
              $code .= sprintf (",%-$len{$att}s", $attr{$att});
            }
          else
            {
              $code .= ' ' x ($len{$att} + 1);
            }
        }
  
      $code .= ' :: ' . $endlt;
  
      my $stmt = &Fxtran::fxtran (statement => $code, fopts => [qw (-line-length 300)]);
  
      $decl->replaceNode ($stmt);
  
    }

  my $n = $buf->Count ();
  $buf->Delete (1, $n);
  $buf->Append (0, split (m/\n/o, $dom->textContent));

  $win->Cursor ($row, $col);
}

1;
