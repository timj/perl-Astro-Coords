#!perl

use strict;
use Test::More tests => 14;
use Data::Dumper;

require_ok("Astro::Coords");
require_ok("Astro::Telescope");
require_ok("Astro::Coords::Offset");

my $off = Astro::Coords::Offset->new( 55, 22, system => "GALACTIC" );
isa_ok($off, "Astro::Coords::Offset");

is( $off->system, "GAL", "Check system conversion");

$off = Astro::Coords::Offset->new( 55, 22, system => "J2008.5" );
isa_ok($off, "Astro::Coords::Offset");

is( $off->system, "J2008.5", "Check system conversion");

# Check offset rotations against those displayed by the OT.
$off = Astro::Coords::Offset->new(100, 0, posang => 45);
my ($x, $y) = map {$_->arcsec()} $off->offsets_rotated();
is(sprintf('%.1f', $x),  70.7, 'Rotated offset: 100,0,45 x');
is(sprintf('%.1f', $y), -70.7, 'Rotated offset: 100,0,45 y');

$off = Astro::Coords::Offset->new(0, 100, posang => 45);
($x, $y) = map {$_->arcsec()} $off->offsets_rotated();
is(sprintf('%.1f', $x), 70.7, 'Rotated offset, 0,100,45 x');
is(sprintf('%.1f', $y), 70.7, 'Rotated offset, 0,100,45 y');

my $coords = Astro::Coords->new(type => 'J2000',
  ra => 1.2, dec => 0.22, name => 'Test');
my $tel = new Astro::Telescope('JCMT');
my $date = new DateTime(year => 2012, month => 4, day => 1,
  hour => 19, minute => 45, second => 59);
$coords->telescope($tel);
$coords->datetime($date);
$off = Astro::Coords::Offset->new(0, 0);
my $coordsoff = $off->apply_offset($coords);

my $dd1 = new Data::Dumper([$coords]);
my $dd2 = new Data::Dumper([$coordsoff]);
$dd1->Sortkeys(1);
$dd2->Sortkeys(1);
is($dd1->Dump(), $dd2->Dump(), 'Before and after offset: no change');

$off = new Astro::Coords::Offset(
  new Astro::Coords::Angle(0.001, unit => 'radians'),
  new Astro::Coords::Angle(0.001, unit => 'radians'));

# Check if the coordinates are nearly just those with the
# offsets added directly
$coordsoff = $off->apply_offset($coords);
ok(nearly_equal($coordsoff->ra2000()->radians(), 1.201), 'After offset, RA');
ok(nearly_equal($coordsoff->dec2000()->radians(), 0.221), 'After offset, DEC');

sub nearly_equal {
  my ($a, $b) = @_;
  return abs($a - $b) < 0.0001;
}
