package Fxtran;

use Fxtran::XPath;
use XML::LibXML;
use List::Util qw (max);
use FileHandle;
use Storable;
use File::Basename;
use Storable;
use Carp qw (croak);
use strict;

use base qw (Exporter);
our @EXPORT = qw (s e F f n t);


sub removeListElement
{

# Remove element from list, take care of removing comma before or after the element

  my $x = shift;

  my $nn = $x->nodeName;

  my ($p) = $x->parentNode;
  
  my @cf = &F ('following-sibling::text()[contains(.,",")]', $x);   
  my @cp = &F ('preceding-sibling::text()[contains(.,",")]', $x);   
  
  if (@cf)
    {   
      $cf[+0]->unbindNode (); 
    }   
  elsif (@cp)
    {   
      $cp[-1]->unbindNode (); 
    }   
  
  $x->parentNode->appendChild (&t (' '));
  my $l = $x->parentNode->lastChild;
  
  $x->unbindNode (); 
  
  while ($l)
    {   
      last if (($l->nodeName ne '#text') && ($l->nodeName ne 'cnt'));
      $l = $l->previousSibling;
      last unless ($l);
      $l->nextSibling->unbindNode;
    }   

  return &F ("./$nn", $p) ? 0 : 1;
}



sub getIndent
{
  my $stmt = shift;

  $stmt or croak;

  my $n = $stmt->previousSibling;

  unless ($n) 
    {    
      if ($stmt->parentNode)
        {
          return &getIndent ($stmt->parentNode);
        }
      return 0;
    }    


  if (($n->nodeName eq '#text') && ($n->data =~ m/\n/o))
    {    
      (my $t = $n->data) =~ s/^.*\n//gsmo;
      return length ($t);
    }    

  if (my $m = $n->lastChild)
    {
      if (($m->nodeName eq '#text') && ($m->data =~ m/\n/o))
        {    
          (my $t = $m->data) =~ s/^.*\n//gsmo;
          return length ($t);
        }    
      return &getIndent ($m);
    }
  elsif (($n->nodeName eq '#text') && ($n->data =~ m/^\s*$/o) && $n->parentNode)
    {
      return length ($n->data) + &getIndent ($n->parentNode);
    }

  return 0;
}

sub reIndent
{
  my ($node, $ns) = @_;

  my $sp = ' ' x $ns; 

  my @cr = &f ('.//text ()[contains (.,"' . "\n" . '")]', $node);

  for my $cr (@cr)
    {    
      (my $t = $cr->data) =~ s/\n/\n$sp/g;
      $cr->setData ($t);
    }
}

sub xpath_by_type
{
  my $type = shift;
  my $size = length ($type);
  return '*[substring(name(),string-length(name())-'.$size.')="-'.$type.'"]';
}

sub _offset
{
  my ($node, $pfound) = @_;

  my $offset = 0;
  for (my $c = $node->previousSibling; $c; $c = $c->previousSibling)
    {
      last if ($c->nodeName eq 'xml-stylesheet');
      my $text = $c->textContent;
      my @text = reverse split (m/(\n)/o, $text);
      for (@text)
        {
          if (m/\n/o)
            {
              $pfound = 1;
              goto FOUND;
            }

          $offset += length ($_);
        }
    }

  if ((! $$pfound) && $node->parentNode)
    {
      $offset += &offset ($node->parentNode, $pfound);
    }

FOUND:

  return $offset;
}

sub offset
{
  my $node = shift;
  return &_offset ($node, \0);
}

# Fold statement workhorse

sub _fold
{
  my ($node, $plen, $indent, $cnt, $len) = @_;
  
  my $shift = 0;

  my @n = &f ('.//text ()', $node);
  if ((scalar (@n) == 1) || ($node->nodeName eq '#text'))
    {
      
      my $lenc = $$plen;

      $$plen += length ($node->textContent);

      my ($lit) = &f ('./ancestor::f:literal-E', $node);
      my ($nam) = &f ('./ancestor::f:named-E', $node);
      my ($ass) = &f ('./ancestor::f:associate', $node);
      my ($arg) = &f ('./ancestor::f:arg', $node);

      if (($$plen > 100) && (! $lit) && (! $nam) && (! $ass) && (! $arg))
        {
          if ($node->textContent =~ m/^\s*,\s*$/o)
            { 
              $lenc = $$plen;
              $node = $node->nextSibling;
              $shift = 1;
            }

          my $c = &n ("<cnt>&amp;</cnt>");

          $node->parentNode->insertBefore ($c, $node);
          $node->parentNode->insertBefore (&t ("\n" . (' ' x $indent)), $node);
          $node->parentNode->insertBefore (&n ("<cnt>&amp;</cnt>"), $node);
          $node->parentNode->insertBefore (&t (" "), $node);
          $$plen = $indent + 2 + length ($node->textContent);

          $lenc++;
          push @$len, $lenc;
          push @$cnt, $c;
        }
    }
  else
    {
      my @c = $node->childNodes;
      while (my $c = shift (@c))
        {
          &_fold ($c, $plen, $indent, $cnt, $len) && shift (@c);
        }
    }

  return $shift;
}


sub expand
{
  my $stmt = shift;

  for (&f ('.//f:cnt', $stmt), &f ('.//f:C', $stmt))
    {
      $_->unbindNode ();
    }
  for (&f ('.//text ()', $stmt))
    {
      my $data = $_->data;
      if ($data =~ m/\n/o)
        {
          $data =~ s/\s+/ /go;
          $_->setData ($data);
        }
    }

  $stmt->normalize ();
}

# Fold a statement

sub fold
{
  my $stmt = shift;

  &expand ($stmt);

  my $indent = &offset ($stmt);

  my $len = $indent;
  my @len;
  my @cnt;
  &_fold ($stmt, \$len, $indent, \@cnt, \@len);

  my ($lenmax) = sort { $b <=> $a } @len;

  for my $i (0 .. $#cnt)
    {
      $cnt[$i]->parentNode->insertBefore (&t (' ' x ($lenmax - $len[$i])), $cnt[$i]);
    }

  $stmt->normalize ();
}

sub t
{
  'XML::LibXML::Text'->new ($_[0]);
}

sub s
{
  &Fxtran::fxtran (statement => $_[0]);
}

sub e
{
  &Fxtran::fxtran (expr => $_[0]);
}

# Returns the statement the element belongs to

sub stmt
{
  my $e = shift;
  my @anc = reverse &f ('./ancestor::*', $e);
  my ($stmt) = grep { $_->nodeName =~ m/-stmt$/o } @anc;
  return $stmt;
}

sub expr
{
  my $e = shift;
  my @anc = reverse &f ('./ancestor::*', $e);
  my ($expr) = grep { $_->nodeName =~ m/-E$/o } @anc;
  return $expr;
}

sub F
{
  my $xpath = &Fxtran::XPath::preprocess (shift (@_));
  return &f ($xpath, @_);
}

sub f
{
  my $xpc = 'XML::LibXML::XPathContext'->new ();
  $xpc->registerNs (f => 'http://fxtran.net/#syntax');

  my $xpath = shift (@_);

  while (@_ && ($xpath =~ s/\?/$_[0]/))
    {
      shift (@_);
    }

  ref ($_[0]) or &croak ("Expected node");

  my @x;

  eval 
    {
      @x = $xpc->findnodes ($xpath, $_[0]);
    };

  if (my $c = $@)
    {
      &croak ($c);
    }

  if (! defined ($_[1]))
    {
    }
  elsif ($_[1] == 1)
    {
      @x = map { $_->textContent } @x;
      for (@x)
        {
          s/\s+//go;
          $_ = uc ($_);
        }
    }
  elsif ($_[1] == 2)
    {
      @x = map { $_->textContent } @x;
    }
  return @x;
}

sub n
{
  my $xml = shift;
  my $doc = 'XML::LibXML'->load_xml (string => '<?xml version="1.0"?><object xmlns="http://fxtran.net/#syntax">' . $xml . '</object>');

  my @childs = $doc->documentElement ()->childNodes ();
  if (@childs > 1)
    {
      return @childs;
    }
  else
    {
      return $childs[0];
    }
}

sub TRUE
{
  &n ('<literal-E>.TRUE.</literal-E>');
}

sub FALSE
{
  &n ('<literal-E>.FALSE.</literal-E>');
}

sub fxtran
{
  use fxtran;

  my %args = @_;

  my @fopts = @{ $args{fopts} || [] };
  my @xopts = @{ $args{xopts} || [] };

  if ($args{string})
    {
      use File::Temp;
      my $fh = 'File::Temp'->new (SUFFIX => '.F90');
      $fh->print ($args{string});
      $fh->flush ();
      system (qw (fxtran -construct-tag -no-include), @fopts, $fh->filename)
        && die ($args{string});
      my $doc = 'XML::LibXML'->load_xml (location => $fh->filename . '.xml', @xopts);
      return $doc;
    }
  elsif ($args{fragment})
    {
      chomp (my $fragment = $args{fragment});
      my $program = << "EOF";
$fragment
END
EOF
      my $xml = &fxtran::run ('-construct-tag', '-no-include', @fopts, $program);
      my $doc = 'XML::LibXML'->load_xml (string => $xml, @xopts);
      $doc = $doc->lastChild->firstChild;

      $doc->lastChild->unbindNode () for (1 .. 2);
      my @c = $doc->childNodes ();

      return @c;
    }
  elsif ($args{statement})
    {
      my $program = << "EOF";
$args{statement}
END 
EOF
      my $xml = &fxtran::run ('-line-length', 300, $program);
      my $doc = 'XML::LibXML'->load_xml (string => $xml, @xopts);
      my $n = $doc->documentElement->firstChild->firstChild;
      return $n;
    }
  elsif ($args{expr})
    {
      my $program = << "EOF";
X = $args{expr}
END
EOF
      my $xml = &fxtran::run ('-line-length', 300, $program);
      my $doc = 'XML::LibXML'->load_xml (string => $xml, @xopts);
      my $n = $doc->documentElement->firstChild->firstChild->lastChild->firstChild;
      return $n;
    }
  elsif (my $f = $args{location})
    {
      use File::stat;
      return unless (-f $f);

      my $dir = $args{dir} || &dirname ($f);
      my $xml = "$dir/" . &basename ($f) . '.xml';

      my @cmd = (qw (fxtran -construct-tag -no-include), @fopts, -o => $xml, $f);
      system (@cmd)
        && croak ("`@cmd' failed\n");

      my $doc = 'XML::LibXML'->load_xml (location => $xml, @xopts);
      return $doc;
    }
  croak "@_";
}

1;
