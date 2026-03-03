#!/bin/zsh
#set -x

replace_uuids_with_names() 
{
    #setopt localoptions extendedglob

    local csv_file=$1
    shift
    local -a target_list=("$@")
    local uuid name rest
    local -A xref
    [[ -f $csv_file ]] || { echo "File not found: $csv_file"; return 1; }

    # Read CSV lines; split on first comma only
    while IFS= read -r line; do
        [[ -z $line ]] && continue

        uuid=${line%%,*}
        rest=${line#*,}
        name=${rest%%,*}   # keep only field 2; ignore extra columns

        # trim leading/trailing whitespace
        uuid=${uuid##[[:space:]]#}; uuid=${uuid%%[[:space:]]#}
        name=${name##[[:space:]]#}; name=${name%%[[:space:]]#}

        [[ -n $uuid ]] && xref[$uuid]=$name
    done < "$csv_file"

    # Emit results
    local item
    for item in "${target_list[@]}"; do
        if [[ -n ${xref[$item]-} ]]; then
            reply+=("$item (${xref[$item]})")
        else
            reply+=("$item")
        fi
    done
}

csv_file="/Users/scott.kendall/Documents/DDMCrossRef.csv"

array=(1165a55e-8f05-4888-9c19-9629aaccee3e
368d14b3-6059-4ec2-8cc5-be8bdd44b20c
51a8a629-def3-4f95-922d-051c5ba7f7c4
6430f438-cd7b-4fc7-8004-b3a6cd37181b
bfeb87b4-4f1f-4772-98b0-12d3d9a475a2
c9c99cf2-ffac-484c-8483-e2cd6e6c6b46
e103cf11-203c-4763-b299-872380830b64)

replace_uuids_with_names "$csv_file" "${array[@]}"
target=("${reply[@]}")
for item in "${target[@]}"; do
    echo $item
done
