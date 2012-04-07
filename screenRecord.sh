#!/bin/sh

echo "Pick the window."
INFO=`xwininfo`
WINGEO=`echo $INFO | grep -oEe 'geometry [0-9]+x[0-9]+' | grep -oEe '[0-9]+x[0-9]+'`
WINCORNORS=`echo $INFO | grep -oEe 'Corners:\s+\+[0-9]+\+[0-9]+' | grep -oEe '[0-9]+\+[0-9]+' | sed -e 's/\+/,/'`

echo $WINGEO
echo $WINCORNORS

BASENAME="$1"
AVINAME="$BASENAME.avi"
FRAMERATE=12

# Grab
AUDIOGRAB="-f alsa -i pulse"
VIDEOGRAB="-f x11grab -s $WINGEO -r $FRAMERATE -i :0.0+$WINCORNORS"

# LAME
AUDIOOUT="-acodec libmp3lame -ac 1 -ab 192k"

# LOSSLESS
AUDIOOUT="-acodec pcm_s16le"

# x264
VIDEOOUT="-vcodec libx264 -vpre lossless_ultrafast -threads 1"

FFMPEG="ffmpeg $AUDIOGRAB $VIDEOGRAB $AUDIOOUT $VIDEOOUT $AVINAME"

echo "Recording in 3..."
sleep 1
echo "2..."
sleep 1
echo "1..."
sleep 1
echo "$FFMPEG"
$FFMPEG

echo "Done."
