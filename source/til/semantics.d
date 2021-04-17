module til.semantics;

import std.array : join;
import std.conv : to;
import std.experimental.logger;

import pegged.grammar;

import til.exceptions;
import til.nodes;
import til.grammar;


int[string]unitsMap;

static this()
{
    unitsMap["K"] = 1000;
    unitsMap["M"] = 1000000;
    unitsMap["G"] = 1000000000;
    unitsMap["Ki"] = 1024;
    unitsMap["Mi"] = 1024 * 1024;
    unitsMap["Gi"] = 1024 * 1024 + 1024;
}


SubProgram analyse(ParseTree p)
{
    switch(p.name)
    {
        case "Til":
            return analyseTil(p);
        default:
            trace("analyse: Not recognized: " ~ p.name);
    }
    assert(0);
}

SubProgram analyseTil(ParseTree p)
{
    foreach(child; p.children)
    {
        switch(child.name)
        {
            case "Til.Program":
                auto program = analyseProgram(child);
                return program;
            default:
                trace("analyseTil: Not recognized: " ~ child.name);
        }
    }
    throw new InvalidException("Program seems invalid");
}

SubProgram analyseProgram(ParseTree p)
{
    foreach(child; p.children)
    {
        switch(child.name)
        {
            case "Til.SubProgram":
                return analyseSubProgram(child);
            default:
                throw new InvalidException(
                    "Program seems invalid. Expecting a SubProgram."
                );
        }
    }
    assert(0);
}

SubProgram analyseSubProgram(ParseTree p)
{
    Pipeline[] pipelines;

    foreach(child; p.children)
    {
        switch(child.name)
        {
            case "Til.Pipeline":
                pipelines ~= analysePipeline(child);
                break;
            case "Til.Comment":
                // NO OP
                break;
            default:
                throw new InvalidException(
                    "Program seems invalid. Expected a Pipeline."
                    ~ " Received a " ~ child.name
                    ~ " (" ~ child.matches[0] ~ ")"
                );
        }
    }
    return new SubProgram(pipelines);
}

Pipeline analysePipeline(ParseTree p)
{
    Command[] commands;

    foreach(child; p.children)
    {
        switch(child.name)
        {
            case "Til.Command":
                commands ~= analyseCommand(child);
                break;
            default:
                throw new InvalidException(
                    "Program seems invalid. Expected a Command"
                    ~ ", received a " ~ child.name ~ "."
                );
        }
    }
    return new Pipeline(commands);
}

Command analyseCommand(ParseTree p)
{
    string name;
    ListItem[] arguments;

    name = p.children[0].matches[0];

    foreach(child; p.children[1..$])
    {
        switch(child.name)
        {
            case "Til.ListItem":
                trace("COMMAND ", name, " ARGUMENT ", child.name, " (", child.matches[0], ")");
                arguments ~= analyseListItem(child);
                trace("COMMAND ", name, " ARGUMENTS ~= ", arguments);
                break;
            default:
                throw new InvalidException(
                    "Program seems invalid. Expecting a List"
                    ~ ", received a " ~ child.name ~ "."
                );
        }
    }
    return new Command(name, arguments);
}

ListItem[] analyseListItems(ParseTree p)
{
    ListItem[] items;

    foreach(child; p.children)
    {
        switch(child.name)
        {
            case "Til.ListItem":
                auto li = analyseListItem(child);
                if (li !is null)
                {
                    items ~= li;
                }
                break;
            default:
                throw new InvalidException(
                    "Program seems invalid. Expecting a ListItem"
                    ~ ", received a " ~ child.name ~ "."
                );
        }
    }
    return items;
}

ListItem analyseListItem(ParseTree p)
{
    foreach(child; p.children)
    {
        switch(child.name)
        {
            case "Til.ExecList":
                return analyseExecList(child);
            case "Til.SubList":
                return analyseSubList(child);
            case "Til.Extraction":
                return analyseExtraction(child);
            case "Til.SimpleList":
                return analyseSimpleList(child);
            case "Til.String":
                return analyseString(child);
            case "Til.Atom":
                return analyseAtom(child);
            default:
                throw new InvalidException(
                    "ListItem seems invalid: "
                    ~ child.name ~ " : "
                    ~ to!string(child.matches)
                );
        }
    }
    assert(0);
}

ExecList analyseExecList(ParseTree p)
{
    return new ExecList(analyseSubProgram(p.children[0]));
}

SubList analyseSubList(ParseTree p)
{
    return new SubList(analyseSubProgram(p.children[0]));
}

Extraction analyseExtraction(ParseTree p)
{
    foreach(child; p.children)
    {
        switch(child.name)
        {
            case "Til.List":
                auto li = analyseListItems(child);
                trace("CREATING Extraction FOR ", to!string(p.matches), " WITH ITEMS ", li);
                return new Extraction(li);
            default:
                throw new InvalidException(
                    "Invalid Item inside SimpleList"
                );
        }
    }
    trace("CREATING EMPTY SimpleList FOR ", to!string(p.matches));
    return new Extraction([]);
}
SimpleList analyseSimpleList(ParseTree p)
{
    foreach(child; p.children)
    {
        switch(child.name)
        {
            case "Til.List":
                auto li = analyseListItems(child);
                trace("CREATING SimpleList FOR ", to!string(p.matches), " WITH ITEMS ", li);
                return new SimpleList(li);
            default:
                throw new InvalidException(
                    "Invalid Item inside SimpleList"
                );
        }
    }
    trace("CREATING EMPTY SimpleList FOR ", to!string(p.matches));
    return new SimpleList([]);
}

// Strings:
String analyseString(ParseTree p)
{
    foreach(index, child; p.children)
    {
        switch(child.name)
        {
            case "Til.SimpleString":
                return analyseSimpleString(child);
            case "Til.SubstString":
                return analyseSubstString(child);
            default:
                throw new Exception(
                    "String seems invalid. Received " ~ child.name ~ "."
                );
        }
    }
    assert(0);
}

SimpleString analyseSimpleString(ParseTree p)
{
    foreach(index, child; p.children)
    {
        switch(child.name)
        {
            case "Til.NotSubstitution":
                return new SimpleString(child.matches[0]);
            default:
                throw new Exception(
                    "SimpleString seems invalid."
                    ~ " Received " ~ child.name ~ "."
                );
        }
    }
    assert(0);
}

SubstString analyseSubstString(ParseTree p)
{
    string[] parts;
    string[int] substitutions;

    foreach(index, child; p.children)
    {
        final switch(child.name)
        {
            case "Til.Substitution":
                substitutions[cast(int)index] = child.matches[0][1..$];
                // fallthrough:
                goto case;
            case "Til.NotSubstitution":
                parts ~= child.matches[0];
        }
    }
    return new SubstString(parts, substitutions);
}

Atom analyseAtom(ParseTree p)
{
    string str = p.matches.join("");
    auto atom = new Atom(str);

    foreach(child; p.children)
    {
        final switch(child.name)
        {
            case "Til.Name":
                if (str[0] == '>')
                {
                    atom.type = ObjectTypes.InputName;
                    atom.repr = str[1..$];
                }
                else
                {
                    atom.type = ObjectTypes.Name;
                }
                break;
            case "Til.Float":
                atom.floatingPoint = to!float(str);
                atom.type = ObjectTypes.Float;
                break;
            case "Til.Integer":
                atom.integer = to!int(str);
                atom.type = ObjectTypes.Integer;
                break;
            case "Til.UnitInteger":
                str = p.matches[0];
                string unit = p.matches[1];
                atom.integer = to!int(str) * unitsMap[unit];
                atom.repr = to!string(atom.integer);
                atom.type = ObjectTypes.Integer;
                break;
            case "Til.Boolean":
                atom.boolean = (
                    child.children[0].name == "Til.BooleanTrue"
                );
                atom.type = ObjectTypes.Boolean;
                break;
            case "Til.Operator":
                atom.type = ObjectTypes.Operator;
                break;
        }
    }
    return atom;
}
