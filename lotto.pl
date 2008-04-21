#!/usr/bin/perl -w

use strict;
use LWP::Simple;
use Date::Manip;
use Data::Dumper;
use HTML::Table;

# http://www.mytelus.com/lotteries/display.do?colID=649west&prov=ab
# http://www.mytelus.com/lotteries/display.do?colID=649west&prov=ab&date=2007-05-02

my $PAGE_HDR = <<PAGE_HDR_END;
<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.0 Transitional//EN">
<html>
  <head>
    <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
    <title>Lotto 6-49</title>
    <link rel="stylesheet" type="text/css" href="style.css"/>
  </head>
  <body>
PAGE_HDR_END

my %numbers;
my @past_dates = ();

my $num_table = 0;
my $date_options = 0;

my $lottoUrl = 'http://www.mytelus.com/lotteries/display.do?colID=649west&prov=ab';

my %our_numbers = ('A' => [2, 7, 11, 25, 29, 48],
                   'B' => [9, 33, 35, 36, 37, 46]);


my @valid_dates = ('2007-02-03', '2008-01-30');

# for debug
#my @valid_dates = ('2007-05-05', '2008-01-30');

sub parseLottoNumbers {
    my $url = shift;
    my $get_past_draws = shift;
    my $doc = get $url;
    my %draw = ();

    for my $line (split("\n", $doc)) {
        if ($line =~ /header.*winning numbers/) {
            $num_table = 1;
        }
        elsif ($line =~ /See results from past dates/)
        {
            $num_table = 0;
            if ($get_past_draws) {
                $date_options = 1;
            }
        }
        elsif ($get_past_draws && ($line =~ /<\/form>/))
        {
            $date_options = 0;
        }
        elsif ($line eq "") {
            next;
        }

        if ($num_table) {
            if ($line =~ /<td><font class="faceonly" size="2">(\d{1,2})<\/font><\/td>/) {
                push (@{ $draw{'numbers'} }, $1);
            }

            if ($line =~ /<td bgcolor="#eeeeee" align="center"><font class="faceonly" size="2">(\d{1,2})<\/font><\/td>/) {
                $draw{'bonus'} = $1;
            }
        }

        if ($get_past_draws && $date_options) {
            if ($line =~ /<option value="(\d{4})-(\d{2})-(\d{2})">/) {
                push (@past_dates, $1 . '-' . $2 . '-' . $3);
            }
        }
    }

    return \%draw;
}

sub in_set {
    my $num = shift;
    my $set = shift;

    foreach (@{ $our_numbers{$set} }) {
        if ($_ == $num) {
            return 1;
        }
    }

    return 0;
}

sub in_draw {
    my $item = shift;
    my $date = shift;

    foreach my $num (@{ $numbers{$date}{'numbers'} }) {
        if ($num == $item) {
            return 1;
        }
    }

    if ($numbers{$date}{'bonus'} == $item) {
        return 2;
    }

    return 0;
}

# the first call is to get the draw dates
parseLottoNumbers($lottoUrl, 1);

foreach my $date (@past_dates) {
    if (Date_Cmp($date, $valid_dates[0]) < 0) {
        last;
    }

    if (Date_Cmp($date, $valid_dates[1]) > 0) {
        next;
    }

    my $url = $lottoUrl . '&date=' . $date;
    print "Fetching numbers for " . $date . "...\n";
    $numbers{$date} = parseLottoNumbers($url, 0);

    if ((scalar @{ $numbers{$date}{'numbers'} } != 6)
        && (scalar @{ $numbers{$date}{'bonus'} } != 1)) {
        die "draw for date $date does not have 6 numbers and a bonus number\n";
    }
}

open(HTML, "> index.html");

print HTML $PAGE_HDR;
print HTML "<h3>Our Numbers</h3>";

my $table = new HTML::Table(-align =>'left', -border => 0);

foreach my $set (keys %our_numbers) {
    $table->addRow(($set . ')', join(' ', @{ $our_numbers{$set} })));
}
print HTML $table->getTable() . "<p/>\n";

print HTML "<h3>Draws</h3>";

$table = new HTML::Table(-align =>'left', -border => 0);
$table->addRow(('',     '',        'Num Matches', '', ''));
$table->setRowHead(1);
$table->setCellColSpan(1, 3, 2);
$table->addRow(('Date', 'Numbers', 'A', 'B', 'Winnings'));
$table->setRowHead(2);

my $row_count = 3;
foreach my $date (reverse sort keys %numbers) {
    my @row;
    my %matches = ();
    my %bonus_matches = ();

    push(@row, $date);
    my @disp_num = ();
    my @keys = sort keys %our_numbers;
    foreach (@{ $numbers{$date}{'numbers'} }) {
        if (in_set($_, $keys[0]) || in_set($_, $keys[1])) {
            push(@disp_num, '<span style="color: #00008B;font-weight: bold;">' . $_ . '</span>');
        }
        else {
            push(@disp_num, $_);
        }
    }

    if (in_set($numbers{$date}{'bonus'}, $keys[0])
        || in_set($numbers{$date}{'bonus'}, $keys[1])) {
        push(@disp_num, '<span style="color: #00008B;font-weight: bold;">'
             . 'b' . $numbers{$date}{'bonus'} . '</span>');
    }
    else {
        push(@disp_num, 'b' . $numbers{$date}{'bonus'});
    }
    push(@row, join(' ', @disp_num));


    # initialize counts
    foreach my $set (keys %our_numbers) {
        $matches{$set} = 0;
        $bonus_matches{$set} = 0;
    }

    # see how many matching numbers we have
    foreach my $set (keys %our_numbers) {
        foreach my $mynum (@{ $our_numbers{$set} }) {
            my $result = in_draw($mynum, $date);
            if ($result == 1) {
                ++$matches{$set};
            }
            elsif ($result == 2) {
                ++$bonus_matches{$set};
            }
        }
    }

    foreach my $set (keys %matches) {
        if ($bonus_matches{$set} == 0) {
            push(@row, $matches{$set});
        }
        else {
            push(@row, $matches{$set} . " +b");
        }
    }

    my @winnings = ();
    foreach my $set (keys %matches) {
        if (($matches{$set} == 2) && ($bonus_matches{$set} == 1)) {
            push(@winnings, "won \$5 with ". $set);
        }
        elsif ($matches{$set} == 3) {
            push(@winnings, "won \$10 with ". $set);
        }
        elsif ($matches{$set} == 4) {
            push(@winnings, "won \$80.10 with ". $set);
        }
        elsif ($matches{$set} == 5) {
            push(@winnings, "won \$2,361.90 with ". $set);
        }
        elsif (($matches{$set} == 5) && ($bonus_matches{$set} == 1)) {
            push(@winnings, "won \$105,790.90 with ". $set);
        }
        elsif ($matches{$set} == 6) {
            push(@winnings, "won GRAND PRIZE with ". $set);
        }
    }

    if (scalar @winnings > 0) {
        push(@row, join(', ', @winnings));
    }

    $table->addRow(@row);
    if (($row_count > 2) && (($row_count & 1) == 0)) {
        $table->setRowBGColor($row_count, '#F7F7F7');
    }
    ++$row_count;
}
print HTML $table->getTable() . "\n";

print HTML "</body>\n</html>";


close HTML;

0;
