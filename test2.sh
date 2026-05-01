i=1
while [ $i -le 100 ]
do
    dune exec test/test_comparison.exe
    echo "Iteration $i"
    ((i++))  # Increment the counter
done