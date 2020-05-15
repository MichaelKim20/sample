module test;

import std.stdio;
import std.algorithm;
import std.stdio;

void reduceEnergy1(ref double energy) {
    energy /= 4;
}

void reduceEnergy2(inout double energy) {
    energy /= 4;
}

void main() {
    double energy = 100;
    reduceEnergy1(energy);
    writeln("New energy: ", energy);

    energy = 100;
    reduceEnergy2(energy);
    writeln("New energy: ", energy);
}
/*
void main()
{
    int[string] values;

    values["B"] = 10;
    writeln(values.byKey());
    values["A"] = 12;
    writeln(values.byKey());
    values["D"] = 9;
    writeln(values.byKey());
    values["C"] = 5;
    writeln(values.byKey());


    string[] v;
    v ~= "Tom";
    v ~= "Jain";
    v ~= "Bill";
    v ~= "Kim";
    sort(v);
    writeln(v);
}
*/