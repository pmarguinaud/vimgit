package vimgit::lang::fortran::transform;

use strict;
use FindBin qw ($Bin);

my $fxtran = 'fxtran';

sub xml_parse
{
  my ($class, %args) = @_;

  my $edtr = $args{editor};

  use FileHandle;
  use File::Path;
  use File::Basename;
  use File::stat;

  eval "use XML::LibXML";

  if ($@)
    {
      &VIM::Msg ("Failed to load XML::LibXML: `$@'");
      return;
    }

  my $path = $args{file}->path (); # after src/local or .vimgit/src=
  my $file = $args{file}{file};    # with src/local or .vimgit/src=

  my $xml = "$edtr->{TOP}/xml=/$path.xml";

  &mkpath (&dirname ($xml));

  if (my $buf = $args{buffer})
    {
      my $text = join ("\n", $buf->Get (1 .. $buf->Count ()));
      $file = "$edtr->{TOP}/xml=/$path";

CHECK1:
# check whether buffer was modified against file
      goto CHECK2
        if (&vimgit::tools::slurp ($file) eq $text);

      'FileHandle'->new (">$file")->print ($text);
    }

CHECK2:
# check whether file was modified against xml
  if ((my $stf = stat ($file)) && (my $stx = stat ($xml)))
    {
      goto DONE
        if ($stf->mtime <= $stx->mtime);
    }

  if (system ($fxtran, qw (-show-lines -no-cpp -construct-tag -line-length 512), -o => $xml, $file))
    {
      &VIM::Msg (sprintf ("Failed to parse `%s'", &basename ($file)));
      return;
    }

DONE:
  return 'XML::LibXML'->load_xml (location => $xml);
}

sub xml_get_row
{
  my ($class, %args) = @_;
  my ($node, $xpc) = @args{qw (node xpc)};
  my @L = $xpc->findnodes ('./preceding::f:L', $node); 
  return scalar (@L);
}

sub xml_find_node_by_row_col
{
  my ($class, %args) = @_;

# row starts from 1, col from 0
  my ($dom, $xpc, $row, $col) = @args{qw (dom xpc row col)};

  my ($L) = $xpc->findnodes ("(.//f:L)[$row]", $dom);

  my $N = $L;
  my ($col1, $col2) = (0);

  MAIN: while (1)
    {
      for (my $s = $N; $s; $s = $s->nextSibling)
        {
          my $text = $s->textContent ();
          my $secr = $text =~ m/\n/goms;

          $col2 = $col1 + length ($text);

          if (($col1 <= $col) && ($col < $col2))
            {
              if ($s->firstChild)
                {
                  $N = $s->firstChild;
                  next MAIN;
                }
              else
                {
                  return $secr ? undef : $s;
                }
            }
          else
            {
              if ($secr)
                {
                  return undef;
                }
              else
                {
                  $col1 = $col2;
                }
            }
        }
      $N = $N->parentNode;
    }

}

sub xpath_by_type
{
  my $class = shift;
  my $type = shift;
  my $size = length ($type);
  return '*[substring(name(),string-length(name())-'.$size.')="-'.$type.'"]';
}

1;
