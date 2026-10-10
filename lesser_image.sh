#!/bin/bash

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

COMPRESSED=0
APPLY_GPT_BACKUP=0
GPT_MOVE_SECOND_HEADER=0
INPUT_PATH=""
OUTPUT_PATH=""
MODE=""
BS=""
COUNT=""


INPUT_SET=0
OUTPUT_SET=0
MODE_SET=0
BS_SET=0
COUNT_SET=0

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME -i <input> -o <output> -m <mode>
               [-c] [-b] [-e] [--bs <bs>] [--count <count>]

Description:
  Acquire a partial image of a block device with its GPT backup, or
  restore one previously acquired.

Options:
  -c, --compressed
      read : output is a tar archive containing image and GPT backup
      write: input is a tar archive as produced by read mode
  -i, --input <path>
      Required. Block device (read) or archive/directory (write).
  -o, --output <path>
      Required. Output file or directory (read) or block device (write).
  -m, --mode <mode>
      Required. 'read' or 'write'.
  --bs <bs>
      Block size for dd (e.g. 1M). Required for mode 'read'.
  --count <count>
      Number of blocks. Required for mode 'read'.
  -b, --gpt-bkp-apply
      Restore the GPT backup onto the resulting image.
  -e, --gpt-move-second-hdr
      Relocate the secondary GPT header to the end of the image (sgdisk -e).
  -h, --help
      Print this message and exit.

Exit status:
  0  success
  1  error

Examples:
  $SCRIPT_NAME -i /dev/sda -o /tmp/image.img -m read --bs 1M --count 10
  $SCRIPT_NAME -c -i /dev/sda -o /tmp/image.tar.gz -m read --bs 1M --count 10
  $SCRIPT_NAME -i /tmp/image.tar.gz -o /dev/sdb -m write -c
  $SCRIPT_NAME -i /tmp/image.dir -o /dev/sdb -m write
EOF
}

TMP_DIR=""
READ_WORK_DIR=""

cleanup_on_exit() {
    for d in "$TMP_DIR" "$READ_WORK_DIR"; do
        if [[ -n "$d" && -d "$d" ]]; then
            rm -rf -- "$d"
        fi
    done
}
trap cleanup_on_exit EXIT

make_tmp_dir() {
    TMP_DIR="$(mktemp -d)"
    echo "$TMP_DIR"
}

IMG_NAME="img.img"
GPT_BACKUP_NAME="gpt-backup.bin"

# User/group that invoked the script via sudo (empty when not run through sudo)
OWNER_UID="${SUDO_UID:-}"
OWNER_GID="${SUDO_GID:-}"

# Build dd size arguments from optional --bs/--count
dd_size_args() {
    local args=()
    [[ $BS_SET -eq 1 ]] && args+=("bs=$BS")
    [[ $COUNT_SET -eq 1 ]] && args+=("count=$COUNT")
    printf '%s\n' "${args[@]}"
}

read_mode() {
    local img_file gpt_backup

    if [[ $COMPRESSED -eq 1 ]]; then
        # Ensure the archive has a .tar.gz extension
        if [[ "$OUTPUT_PATH" != *.tar.gz ]]; then
            OUTPUT_PATH="$OUTPUT_PATH.tar.gz"
        fi

        local out_dir rand
        out_dir="$(dirname "$OUTPUT_PATH")"
        mkdir -p "$out_dir"
        for _ in 1 2 3 4 5; do
            rand="$(printf '%05d%05d%05d' "$RANDOM" "$RANDOM" "$RANDOM")"
            if mkdir -m 0700 "$out_dir/.lesser_image.$rand" 2>/dev/null; then
                READ_WORK_DIR="$out_dir/.lesser_image.$rand"
                break
            fi
        done
        if [[ -z "$READ_WORK_DIR" ]]; then
            echo "Error: could not create staging directory in '$out_dir'." >&2
            exit 1
        fi
        if [[ "$(stat -f -c %T "$READ_WORK_DIR" 2>/dev/null)" == "tmpfs" ]]; then
            echo "Warning: staging directory '$READ_WORK_DIR' is on tmpfs and may be too small for the image." >&2
        fi
        img_file="$READ_WORK_DIR/$IMG_NAME"
        gpt_backup="$READ_WORK_DIR/$GPT_BACKUP_NAME"
    else
        mkdir -p "$OUTPUT_PATH"
        img_file="$OUTPUT_PATH/$IMG_NAME"
        gpt_backup="$OUTPUT_PATH/$GPT_BACKUP_NAME"
    fi

    echo "dd: '$INPUT_PATH' -> '$img_file' (bs=$BS count=$COUNT)"
    dd if="$INPUT_PATH" of="$img_file" bs="$BS" count="$COUNT" status=progress

    echo "sgdisk: backing up GPT from '$INPUT_PATH' -> '$gpt_backup'"
    sgdisk --backup="$gpt_backup" "$INPUT_PATH" >/dev/null

    if [[ $APPLY_GPT_BACKUP -eq 1 ]]; then
        echo "sgdisk: restoring GPT backup onto image"
        sgdisk --load-backup="$gpt_backup" "$img_file" >/dev/null
    fi

    if [[ $GPT_MOVE_SECOND_HEADER -eq 1 ]]; then
        echo "sgdisk: relocating secondary GPT header"
        sgdisk -e "$img_file" >/dev/null
    fi

    if [[ $COMPRESSED -eq 1 ]]; then
        echo "tar: creating archive '$OUTPUT_PATH'"
        tar czf "$OUTPUT_PATH" -C "$READ_WORK_DIR" "$IMG_NAME" "$GPT_BACKUP_NAME"
        rm -rf -- "$READ_WORK_DIR"
        READ_WORK_DIR=""
    fi

    # Hand the output back to the invoking user when run via sudo
    if [[ -n "$OWNER_UID" ]]; then
        chown "${OWNER_UID}:${OWNER_GID}" "$OUTPUT_PATH"
        if [[ $COMPRESSED -ne 1 ]]; then
            chown "${OWNER_UID}:${OWNER_GID}" "$OUTPUT_PATH/$IMG_NAME" "$OUTPUT_PATH/$GPT_BACKUP_NAME"
        fi
    fi
}

write_mode() {
    local gpt_backup dd_size_str
    dd_size_str="$(dd_size_args | paste -sd ' ' -)"
    if [[ -n "$dd_size_str" ]]; then
        dd_size_str=" ($dd_size_str)"
    fi

    if [[ $COMPRESSED -eq 1 ]]; then
        if [[ ! -f "$INPUT_PATH" ]]; then
            echo "Error: input archive '$INPUT_PATH' not found (required with -c)." >&2
            exit 1
        fi

      
        local archive_listing
        echo "tar: validating archive"
		if ! archive_listing="$(tar tzf "$INPUT_PATH" 2>/dev/null)"; then
            echo "Error: '$INPUT_PATH' is not a valid tar archive (required with -c)." >&2
            exit 1
        fi
        if ! grep -qx "$IMG_NAME" <<<"$archive_listing" || ! grep -qx "$GPT_BACKUP_NAME" <<<"$archive_listing"; then
            echo "Error: archive '$INPUT_PATH' must contain '$IMG_NAME' and '$GPT_BACKUP_NAME'." >&2
            exit 1
        fi

        if [[ $APPLY_GPT_BACKUP -eq 1 ]]; then
            make_tmp_dir
            gpt_backup="$TMP_DIR/$GPT_BACKUP_NAME"
            echo "tar: extracting GPT backup from '$INPUT_PATH'"
            tar xzf "$INPUT_PATH" -C "$TMP_DIR" "$GPT_BACKUP_NAME"
        fi

        echo "dd: '$INPUT_PATH/$IMG_NAME' -> '$OUTPUT_PATH'$dd_size_str"
        tar xzf "$INPUT_PATH" -O "$IMG_NAME" | dd of="$OUTPUT_PATH" $(dd_size_args) status=progress iflag=fullblock
    else
        if [[ ! -d "$INPUT_PATH" ]] || [[ ! -f "$INPUT_PATH/$IMG_NAME" ]] || [[ ! -f "$INPUT_PATH/$GPT_BACKUP_NAME" ]]; then
            echo "Error: '$INPUT_PATH' must be a directory containing '$IMG_NAME' and '$GPT_BACKUP_NAME'." >&2
            exit 1
        fi
        gpt_backup="$INPUT_PATH/$GPT_BACKUP_NAME"

        echo "dd: '$INPUT_PATH/$IMG_NAME' -> '$OUTPUT_PATH'$dd_size_str"
        dd if="$INPUT_PATH/$IMG_NAME" of="$OUTPUT_PATH" $(dd_size_args) status=progress conv=sync
    fi

    if [[ $APPLY_GPT_BACKUP -eq 1 ]]; then
        echo "sgdisk: restoring GPT backup onto '$OUTPUT_PATH'"
        sgdisk --load-backup="$gpt_backup" "$OUTPUT_PATH" >/dev/null
    fi

    if [[ $GPT_MOVE_SECOND_HEADER -eq 1 ]]; then
        echo "sgdisk: relocating secondary GPT header on '$OUTPUT_PATH'"
        sgdisk -e "$OUTPUT_PATH" >/dev/null
    fi
}

for binary in sgdisk tar; do
    if ! command -v "$binary" >/dev/null 2>&1; then
        echo "Error: required utility '$binary' not found in PATH." >&2
        exit 1
    fi
done


while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--compressed)
            COMPRESSED=1
            shift
            ;;
        -b|--gpt-bkp-apply)
            APPLY_GPT_BACKUP=1
            shift
            ;;
        -e|--gpt-move-second-hdr)
            GPT_MOVE_SECOND_HEADER=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -i|--input)
            if [[ $# -lt 2 ]]; then
                echo "Error: option '$1' requires an argument." >&2
                usage >&2
                exit 1
            fi
            INPUT_PATH="$2"
            INPUT_SET=1
            shift 2
            ;;
        -o|--output)
            if [[ $# -lt 2 ]]; then
                echo "Error: option '$1' requires an argument." >&2
                usage >&2
                exit 1
            fi
            OUTPUT_PATH="$2"
            OUTPUT_SET=1
            shift 2
            ;;
        -m|--mode)
            if [[ $# -lt 2 ]]; then
                echo "Error: option '$1' requires an argument." >&2
                usage >&2
                exit 1
            fi
            MODE="$2"
            MODE_SET=1
            shift 2
            ;;
        --bs)
            if [[ $# -lt 2 ]]; then
                echo "Error: option '$1' requires an argument." >&2
                usage >&2
                exit 1
            fi
            BS="$2"
            BS_SET=1
            shift 2
            ;;
        --count)
            if [[ $# -lt 2 ]]; then
                echo "Error: option '$1' requires an argument." >&2
                usage >&2
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: invalid count '$2'. Expected a number." >&2
                usage >&2
                exit 1
            fi
            COUNT="$2"
            COUNT_SET=1
            shift 2
            ;;
        *)
            echo "Error: unknown option '$1'." >&2
            usage >&2
            exit 1
            ;;
    esac
done

MISSING=0
if [[ $INPUT_SET -ne 1 ]]; then
    echo "Error: mandatory option '-i <path>' is missing." >&2
    MISSING=1
fi
if [[ $OUTPUT_SET -ne 1 ]]; then
    echo "Error: mandatory option '-o <path>' is missing." >&2
    MISSING=1
fi
if [[ $MODE_SET -ne 1 ]]; then
    echo "Error: mandatory option '-m --mode <mode>' is missing." >&2
    MISSING=1
fi
if [[ $MODE_SET -eq 1 && "$MODE" != "read" && "$MODE" != "write" ]]; then
    echo "Error: invalid value for -m: '$MODE' (expected 'read' or 'write')." >&2
    MISSING=1
fi
if [[ $BS_SET -ne 1 && "$MODE" == "read" ]]; then
    echo "Error: --bs is required when -m is 'read'." >&2
    MISSING=1
fi
if [[ $COUNT_SET -ne 1 && "$MODE" == "read" ]]; then
    echo "Error: --count is required when -m is 'read'." >&2
    MISSING=1
fi
if [[ $MISSING -ne 0 ]]; then
    usage >&2
    exit 1
fi

case "$MODE" in
    read)
        read_mode
        ;;
    write)
        write_mode
        ;;
esac
