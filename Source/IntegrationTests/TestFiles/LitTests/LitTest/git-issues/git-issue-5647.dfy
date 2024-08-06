// RUN: %testDafnyForEachCompiler "%s"

// Verify shadowing

function {:tailrecursion} GetSum(
  a_b': nat,
  ac_c: string)
  : string
{
  if a_b' == 0 then
    ac_c
  else
    var j := a_b';
    var a_b' := if a_b' % 2 == 0 then "1" else "0";
    GetSum(j - 1, ac_c + a_b')
}

method Main() {
  print GetSum(10, ""), "\n";
}