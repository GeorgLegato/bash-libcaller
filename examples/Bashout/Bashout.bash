#!/usr/bin/env bash
# Remove set -e to see errors
# set -e

# Directory setup
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

# --- Init Window (Must be first) ---
SCREEN_W=800
SCREEN_H=450
raylib InitWindow $SCREEN_W $SCREEN_H "Bash Breakout (Raylib)"
raylib SetTargetFPS 60

# --- Audio Setup ---
# Use callso to call Raylib functions; support nested Sound struct signature
# Raylib's Sound struct: { AudioStream stream; unsigned int frameCount; }
# AudioStream: { rAudioBuffer *buffer; rAudioProcessor *processor; unsigned int sampleRate; unsigned int sampleSize; unsigned int channels; }
# Nested Sound struct: {{ptr,ptr,u32,u32,u32},u32}

# Initialize Audio
raylib SetTraceLogLevel 5 # LOG_WARNING to prevent stdout pollution
raylib InitAudioDevice

# Load Sounds
ABS_ASSETS="$BASE_DIR/assets"
SOUND_SIG="{{ptr,ptr,u32,u32,u32},u32}"

load_sound_safe() {
    local file="$1"
    local outvar="$2"
    # LoadSound returns a struct. callso allocates memory and returns address as string.
    callso -v ptr "$LIB_PATH" "$SOUND_SIG str" "LoadSound" "$file"
    eval "$outvar='$ptr'"
}

load_sound_safe "$ABS_ASSETS/paddle.wav" SND_PADDLE
load_sound_safe "$ABS_ASSETS/wall.wav" SND_WALL
load_sound_safe "$ABS_ASSETS/brick.wav" SND_BRICK
load_sound_safe "$ABS_ASSETS/die.wav" SND_DIE

play_sound() {
    local id=$1
    local snd=""
    if [[ "$id" == "paddle" ]]; then snd="$SND_PADDLE"; fi
    if [[ "$id" == "wall" ]]; then snd="$SND_WALL"; fi
    if [[ "$id" == "brick" ]]; then snd="$SND_BRICK"; fi
    if [[ "$id" == "die" ]]; then snd="$SND_DIE"; fi

    if [[ -n "$snd" ]]; then
        callso "$LIB_PATH" "void $SOUND_SIG" "PlaySound" "$snd"
    fi
}

# Colors (Little Endian: AABBGGRR)
get_color() {
    local r=$1; local g=$2; local b=$3; local a=$4
    echo $(( r | (g << 8) | (b << 16) | (a << 24) ))
}

WHITE=$(get_color 255 255 255 255)
BLACK=$(get_color 0 0 0 255)
RED=$(get_color 230 41 55 255)
GREEN=$(get_color 0 228 48 255)
BLUE=$(get_color 0 121 241 255)
YELLOW=$(get_color 253 249 0 255)

# Game Constants
SCREEN_W=800
SCREEN_H=450
PADDLE_W=100
PADDLE_H=20
BALL_R=8
BRICK_ROWS=5
BRICK_COLS=15
BRICK_W=$(( SCREEN_W / BRICK_COLS ))
BRICK_H=20

# Game State
paddle_x=$(( SCREEN_W / 2 - PADDLE_W / 2 ))
paddle_y=$(( SCREEN_H - 40 ))
paddle_speed=12

ball_x=$(( SCREEN_W / 2 ))
ball_y=$(( SCREEN_H / 2 ))
ball_dx=6
ball_dy=-6
lives=3

# Bricks
declare -a bricks_active
declare -a bricks_x
declare -a bricks_y
declare -a bricks_color

init_bricks() {
    # BASH Pattern (15 cols x 5 rows)
    # A: 010 101 111 101 101
    # S: 011 100 010 001 110
    local row0="110001000110101"
    local row1="101010101000101"
    local row2="110011100100111"
    local row3="101010100010101"
    local row4="110010101100101"
    
    local rows=("$row0" "$row1" "$row2" "$row3" "$row4")
    
    local i=0
    for ((r=0; r<BRICK_ROWS; r++)); do
        local row_str="${rows[$r]}"
        for ((c=0; c<BRICK_COLS; c++)); do
            # Get char at index c
            local char="${row_str:$c:1}"
            
            bricks_active[$i]=$char
            bricks_x[$i]=$(( c * BRICK_W ))
            bricks_y[$i]=$(( r * BRICK_H + 40 ))
            
            if (( r == 0 )); then bricks_color[$i]=$RED
            elif (( r == 1 )); then bricks_color[$i]=$GREEN
            elif (( r == 2 )); then bricks_color[$i]=$BLUE
            else bricks_color[$i]=$YELLOW
            fi
            
            ((i++))
        done
    done
}

init_bricks

# Optional runtime profiling: set DEBUG_PROFILE=1 to print FPS once per second
if [[ "$DEBUG_PROFILE" == "1" ]]; then
    profile_last=$SECONDS
fi

# Optional key debug: set DEBUG_KEYS=1 to print GetKeyPressed values for 3s
if [[ "$DEBUG_KEYS" == "1" ]]; then
    # If enabled, print keypress debug info to stderr for 3s
    end_time=$((SECONDS + 3))
    while (( SECONDS < end_time )); do
        kp=$(raylib GetKeyPressed)
        if [[ -n "$kp" && "$kp" != "0" ]]; then
            echo "GetKeyPressed=$kp" >&2
        fi
        sleep 0.05
    done
fi

while true; do
    # Check close
    callso -v should_close "$LIB_PATH" "bool" "WindowShouldClose"
    if [[ "$should_close" == "1" ]]; then
        break
    fi

    # Optional profiling: print FPS once per second when enabled
    if [[ "$DEBUG_PROFILE" == "1" ]]; then
        if (( SECONDS - profile_last >= 1 )); then
            callso -v fps "$LIB_PATH" "i32" "GetFPS"
            echo "FPS=$fps" >&2
            profile_last=$SECONDS
        fi
    fi

    # --- Update ---
    
    # Input (KEY_RIGHT=262, KEY_LEFT=263, KEY_A=65, KEY_D=68, KEY_Q=81, KEY_E=69, KEY_H=72, KEY_L=76)
    # Also check GetKeyPressed once per frame as a fallback for some keyboards
    callso -v last_key "$LIB_PATH" "i32" "GetKeyPressed"
    if [[ "$last_key" == "263" ]]; then paddle_x=$(( paddle_x - paddle_speed )); fi
    if [[ "$last_key" == "262" ]]; then paddle_x=$(( paddle_x + paddle_speed )); fi

    # Read key states directly into variables to avoid subshells
    callso -v k_left "$LIB_PATH" "bool i32" "IsKeyDown" 263
    callso -v k_a "$LIB_PATH" "bool i32" "IsKeyDown" 65
    callso -v k_q "$LIB_PATH" "bool i32" "IsKeyDown" 81
    callso -v k_h "$LIB_PATH" "bool i32" "IsKeyDown" 72

    if [[ "$k_left" == "1" || "$k_a" == "1" || "$k_q" == "1" || "$k_h" == "1" ]]; then
        paddle_x=$(( paddle_x - paddle_speed ))
    fi

    callso -v k_right "$LIB_PATH" "bool i32" "IsKeyDown" 262
    callso -v k_d "$LIB_PATH" "bool i32" "IsKeyDown" 68
    callso -v k_e "$LIB_PATH" "bool i32" "IsKeyDown" 69
    callso -v k_l "$LIB_PATH" "bool i32" "IsKeyDown" 76

    if [[ "$k_right" == "1" || "$k_d" == "1" || "$k_e" == "1" || "$k_l" == "1" ]]; then
        paddle_x=$(( paddle_x + paddle_speed ))
    fi
    
    # Clamp Paddle
    if (( paddle_x < 0 )); then paddle_x=0; fi
    if (( paddle_x > SCREEN_W - PADDLE_W )); then paddle_x=$(( SCREEN_W - PADDLE_W )); fi
    
    # Ball Movement
    ball_x=$(( ball_x + ball_dx ))
    ball_y=$(( ball_y + ball_dy ))
    
    # Wall Collision
    if (( ball_x < BALL_R || ball_x > SCREEN_W - BALL_R )); then
        ball_dx=$(( -ball_dx ))
        play_sound "wall"
    fi
    if (( ball_y < BALL_R )); then
        ball_dy=$(( -ball_dy ))
        play_sound "wall"
    fi
    
    # Paddle Collision (AABB)
    bx=$(( ball_x - BALL_R ))
    by=$(( ball_y - BALL_R ))
    bd=$(( BALL_R * 2 ))
    
    if (( bx < paddle_x + PADDLE_W && bx + bd > paddle_x && by < paddle_y + PADDLE_H && by + bd > paddle_y )); then
        ball_dy=$(( -ball_dy ))
        ball_y=$(( paddle_y - BALL_R - 1 ))
        play_sound "paddle"
        
        # Simple English (spin) effect based on hit position
        center_paddle=$(( paddle_x + PADDLE_W / 2 ))
        dist=$(( ball_x - center_paddle ))
        ball_dx=$(( dist / 5 ))
    fi
    
    # Brick Collision
    total_bricks=$(( BRICK_ROWS * BRICK_COLS ))
    for ((i=0; i<total_bricks; i++)); do
        if (( bricks_active[i] == 1 )); then
            brx=${bricks_x[$i]}
            bry=${bricks_y[$i]}
            
            # Check collision
            if (( bx < brx + BRICK_W && bx + bd > brx && by < bry + BRICK_H && by + bd > bry )); then
                bricks_active[$i]=0
                ball_dy=$(( -ball_dy ))
                play_sound "brick"
                break # Handle one collision per frame
            fi
        fi
    done
    
    # Game Over Reset
    if (( ball_y > SCREEN_H )); then
        play_sound "die"
        lives=$(( lives - 1 ))
        if (( lives > 0 )); then
            ball_x=$(( SCREEN_W / 2 ))
            ball_y=$(( SCREEN_H / 2 ))
            ball_dy=-6
            ball_dx=0
        else
            # Reset Game
            lives=3
            ball_x=$(( SCREEN_W / 2 ))
            ball_y=$(( SCREEN_H / 2 ))
            ball_dy=-6
            ball_dx=0
            init_bricks
        fi
    fi

    # --- Draw ---
    raylib BeginDrawing
    raylib ClearBackground $BLACK

    # Frame counter for selective drawing to reduce callso overhead
    frame_counter=$((frame_counter + 1))
    
    # Draw Lives (Upper Center)
    # Text width approx 80px for "Lives: 3" at size 20
    raylib DrawText "Lives: $lives" $(( SCREEN_W / 2 - 40 )) 10 20 $WHITE
    
    # Draw Bricks (draw every frame now that libffi is fast)
    for ((i=0; i<total_bricks; i++)); do
        if (( bricks_active[i] == 1 )); then
            raylib DrawRectangle ${bricks_x[$i]} ${bricks_y[$i]} $(( BRICK_W - 2 )) $(( BRICK_H - 2 )) ${bricks_color[$i]}
        fi
    done
    
    # Draw Paddle
    raylib DrawRectangle $paddle_x $paddle_y $PADDLE_W $PADDLE_H $WHITE
    
    # Draw Ball
    # DrawCircle(int centerX, int centerY, float radius, Color color)
    raylib DrawCircle $ball_x $ball_y $BALL_R $WHITE
    
    raylib DrawFPS 10 10
    raylib EndDrawing
done

# Cleanup Audio
callso "$LIB_PATH" "void $SOUND_SIG" "UnloadSound" "$SND_PADDLE"
callso "$LIB_PATH" "void $SOUND_SIG" "UnloadSound" "$SND_WALL"
callso "$LIB_PATH" "void $SOUND_SIG" "UnloadSound" "$SND_BRICK"
callso "$LIB_PATH" "void $SOUND_SIG" "UnloadSound" "$SND_DIE"
raylib CloseAudioDevice

raylib CloseWindow
