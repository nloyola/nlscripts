#!/usr/bin/perl -w

use strict;
use File::Basename;
use File::Find;
use Getopt::Long;
use IMDB::Film;
use File::Listing;
use HTML::Table;

my $SCRIPTNAME = basename ($0);

my $USAGE = <<USAGE_END;
Usage: $SCRIPTNAME [options] PATH

USAGE_END

my $PAGE_HDR = <<PAGE_HDR_END;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN">
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <title>Movie Ratings</title>
    <link rel="stylesheet" type="text/css" href="main.css"/>
  </head>
  <body>
PAGE_HDR_END

my %movie_names;
my %rated_movies;
my $debug;
my ($tdir, $name, $type, $size, $mtime, $mode);
my $table;
my $unrated = -1;

sub getImdbInfo {
    my $name = shift;
    my ($key, $rating, $vnum) = (0, 0, 0);
    my ($titleLower, $nameLower);

    my $imdbObj = new IMDB::Film(crit => $name, debug => 0, cache => 1);

    if(!$imdbObj->status) {
        print "Something wrong for $name: ".$imdbObj->error . "\n";
        return;
    }

    my $href = "<a href=\"http://www.imdb.com/title/tt" . $imdbObj->code()
        . "/\">" . $imdbObj->title() . "</a>";
    ($titleLower = $imdbObj->title()) =~ tr/A-Z/a-z/;
    ($nameLower = $name) =~ tr/A-Z/a-z/;
    if (($titleLower ne $nameLower) && ($name !~ /^tt/)) {
        $href .= "<br/>" . $name;
    }
    ($rating, $vnum) = $imdbObj->rating();

    if (!defined($rating)) {
        $key = $unrated;
        $unrated--;
        $rating = "n/a";
        $vnum = "n/a";
    }
    else {
        $key = $rating * $vnum * 10;
    }

    my $genres = join(" ", @{$imdbObj->genres()});
    if (exists($rated_movies{$key})) {
	$key .= " "; # just append a space to make it appear different
    }
    push(@{$rated_movies{$key}}, ($href, $genres, $imdbObj->year(),
                                  $rating, $vnum));
}

sub readDir {
    my $tdir = shift;

    for (parse_dir(`ls -l $tdir`)) {
        ($name, $type, $size, $mtime, $mode) = @$_;
        next if ($type ne 'd'); # only look for directories

        if ($name !~ /(burned|burned2|Music|other|Season|SW|TV|_)/) {
            $movie_names{$name} = 0;
        }

        for (parse_dir(`ls -l "$tdir/$name"`)) {
            my ($name2, $type2, $size2, $mtime2, $mode2);

            ($name2, $type2, $size2, $mtime2, $mode2) = @$_;
            if ($name2 =~ /tt(\d+)\.txt/) {
                #print $name2 . " " . $1 . "\n";
                $movie_names{$name} = 'tt' . $1;
            }
        }
    }
}

sub makeTable {
    $table = new HTML::Table(-align =>'center', -border => 0);

    foreach $name (sort keys %movie_names) {
        print "... " . $name . " ...\n";
        if ($movie_names{$name} =~ /^tt/) {
            getImdbInfo($movie_names{$name});
        }
        else {
            getImdbInfo($name);
        }
    }

    # sort in decending order
    my $row = 0;
    foreach my $rating (sort {$b <=> $a} keys %rated_movies) {
        $table->addRow(@{$rated_movies{$rating}});
        if (($row & 1) == 0) {
            $table->setRowBGColor($row, '#CCFFFF');
        }
        $row++;
    }

    return $table;
}

if (!GetOptions ('debug' => \$debug)) {
    die "ERROR: bad options in command line\n";
}

if ($#ARGV < 0) {
    $tdir = "/home/nelson/torrents";
}
else {
    $tdir = $ARGV[0];
}

print "tdir: " . $tdir . "\n";

readDir($tdir);

$table = makeTable();

open(HTML, "> index.html");

print HTML $PAGE_HDR
    . "<h1>Movies in " . $tdir . "</h1>"
    . $table->getTable()
    . "</body>\n</html>";

close HTML;

0;
