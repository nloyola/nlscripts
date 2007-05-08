#!/usr/bin/perl -w

use strict;
use LWP::Simple;
use Date::Manip;
use Data::Dumper;

# http://www.mytelus.com/lotteries/display.do?colID=649west&prov=ab
# http://www.mytelus.com/lotteries/display.do?colID=649west&prov=ab&date=2007-05-02

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

    my $url = $lottoUrl . '&date=' . $date;
    print "Fetching numbers for " . $date . "...\n";
    $numbers{$date} = parseLottoNumbers($url, 0);

    if ((scalar @{ $numbers{$date}{'numbers'} } != 6)
        && (scalar @{ $numbers{$date}{'bonus'} } != 1)) {
        die "draw for date $date does not have 6 numbers and a bonus number\n";
    }
}

print "\n\nOur numbers:\n";
foreach my $set (keys %our_numbers) {
    print "  " . $set . ") " . join(', ', @{ $our_numbers{$set} }) . "\n";
}

print "\n\t\t\t\t\tNum Matches\n"
    . "Draw\t\tNumbers\t\t\tA\tB\tWinnings\n"
    . "--------------- ----------------------- ------- ------- ---------------\n";

foreach my $date (reverse sort keys %numbers) {
    my @row;
    my %matches = ();
    my %bonus_matches = ();

    push(@row, $date);
    push(@row, join(' ', @{ $numbers{$date}{'numbers'} }) . ' b'
         . $numbers{$date}{'bonus'});

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

    print join("\t", @row) . "\n";
}
