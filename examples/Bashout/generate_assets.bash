#!/usr/bin/env bash

# Helper to write Little Endian 4-byte int to stdout (raw bytes)
p32() {
    local v=$1
    printf "\\x$(printf %02x $((v & 0xff)))"
    printf "\\x$(printf %02x $(( (v >> 8) & 0xff )))"
    printf "\\x$(printf %02x $(( (v >> 16) & 0xff )))"
    printf "\\x$(printf %02x $(( (v >> 24) & 0xff )))"
}

# Helper to write Little Endian 2-byte int to stdout (raw bytes)
p16() {
    local v=$1
    printf "\\x$(printf %02x $((v & 0xff)))"
    printf "\\x$(printf %02x $(( (v >> 8) & 0xff )))"
}

generate_wav_header() {
    local size=$1
    local sample_rate=44100
    local num_channels=1
    local bits_per_sample=8
    
    local chunk_size=$((36 + size))
    local byte_rate=$((sample_rate * num_channels * bits_per_sample / 8))
    local block_align=$((num_channels * bits_per_sample / 8))
    
    printf "RIFF"
    p32 $chunk_size
    printf "WAVEfmt "
    p32 16          # Subchunk1Size
    p16 1           # AudioFormat (PCM)
    p16 $num_channels
    p32 $sample_rate
    p32 $byte_rate
    p16 $block_align
    p16 $bits_per_sample
    printf "data"
    p32 $size
}

generate_square_wave() {
    local filename=$1
    local freq=$2
    local duration_ms=$3
    local sample_rate=44100
    
    local num_samples=$(( sample_rate * duration_ms / 1000 ))
    local period=$(( sample_rate / freq ))
    local half_period=$(( period / 2 ))
    
    echo "Generating $filename ($freq Hz, ${duration_ms}ms)..."
    
    # Use a subshell to capture all output and redirect to file
    # We pipe to 'xargs -0 printf' or similar? No.
    # We need to output raw bytes.
    # printf in bash interprets \xHH.
    # So if p32 outputs "\x10", and we capture it...
    # The issue is mixing literal strings and escaped hex.
    
    # NEW APPROACH: Construct the entire hex string for the header and use xxd or perl to write it.
    # Or just use perl for everything.
    
    (
        # Header
        perl -e '
            sub p32 { print pack("V", $_[0]); }
            sub p16 { print pack("v", $_[0]); }
            
            $size = '$num_samples';
            $sr = '$sample_rate';
            $ch = 1;
            $bits = 8;
            
            $chunk_size = 36 + $size;
            $byte_rate = $sr * $ch * $bits / 8;
            $block_align = $ch * $bits / 8;
            
            print "RIFF";
            p32($chunk_size);
            print "WAVEfmt ";
            p32(16);
            p16(1);
            p16($ch);
            p32($sr);
            p32($byte_rate);
            p16($block_align);
            p16($bits);
            print "data";
            p32($size);
            
            # Data
            $period = int($sr / '$freq');
            $half = int($period / 2);
            $high = chr(200);
            $low = chr(56);
            
            $samples_written = 0;
            while ($samples_written < $size) {
                print $high x $half;
                print $low x $half;
                $samples_written += $period;
            }
        '
    ) > "$filename"
}

generate_noise() {
    local filename=$1
    local duration_ms=$2
    local sample_rate=44100
    local num_samples=$(( sample_rate * duration_ms / 1000 ))
    
    echo "Generating $filename (Noise, ${duration_ms}ms)..."
    
    (
        perl -e '
            sub p32 { print pack("V", $_[0]); }
            sub p16 { print pack("v", $_[0]); }
            
            $size = '$num_samples';
            $sr = '$sample_rate';
            $ch = 1;
            $bits = 8;
            
            $chunk_size = 36 + $size;
            $byte_rate = $sr * $ch * $bits / 8;
            $block_align = $ch * $bits / 8;
            
            print "RIFF";
            p32($chunk_size);
            print "WAVEfmt ";
            p32(16);
            p16(1);
            p16($ch);
            p32($sr);
            p32($byte_rate);
            p16($block_align);
            p16($bits);
            print "data";
            p32($size);
        '
        head -c $num_samples /dev/urandom
    ) > "$filename"
}

# Generate the assets
mkdir -p assets
generate_square_wave "assets/paddle.wav" 440 50
generate_square_wave "assets/wall.wav" 880 50
generate_square_wave "assets/brick.wav" 1200 50
generate_noise "assets/die.wav" 200
