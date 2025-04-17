#!/bin/zsh

passlimit=60

echo "old" $1
echo "new "$2
autoload -Uz calendar_scandate

function duration_in_days ()
{
    local start end
    calendar_scandate $1        
    start=$REPLY        
    calendar_scandate $2        
    end=$REPLY        
    echo $(( ( end - start ) / ( 24 * 60 * 60 ) ))
}
daysdiff=$(duration_in_days $1 $2)

if [[ $passlimit-$daysdiff -le 7 ]]; then
    echo "It has been $daysdiff since your changed your Password. Your password is going to expire in $((passlimit-$daysdiff)) days"
fi

