module til.process;

import std.array : join, split;
import std.container : DList;

import til.nodes;
import til.modules;
import til.scheduler;

debug
{
    import std.stdio;
}

enum ProcessState
{
    New,
    Running,
    Receiving,
    Waiting,
}


class Process
{
    SubProgram program;
    Process parent;

    auto state = ProcessState.New;

    ListItem[64] stack;
    ulong stackPointer = 0;
    Items[string] variables;

    // PIDs:
    static uint counter = 0;
    uint index;

    // Scheduling
    Scheduler scheduler = null;
    const uint msgboxSize = 4;
    ListItem[] msgbox;

    this(Process parent)
    {
        this.index = this.counter++;
        this.parent = parent;
        if (parent !is null)
        {
            this.stack = parent.stack[];
            this.stackPointer = parent.stackPointer;
            this.program = parent.program;
        }
    }
    this(Process parent, SubProgram program)
    {
        this(parent);
        this.program = program;
    }

    // The "heap":
    // auto x = escopo["x"];
    Items opIndex(string name)
    {
        Items* value = (name in this.variables);
        if (value is null && this.parent !is null)
        {
            return this.parent[name];
        }
        else
        {
            debug {stderr.writeln(name, " is ", *value);}
            return *value;
        }
    }
    // escopo["x"] = new Atom(123);
    void opIndexAssign(ListItem value, string name)
    {
        debug {stderr.writeln(name, " = ", value);}
        variables[name] = [value];
    }
    void opIndexAssign(Items value, string name)
    {
        debug {stderr.writeln(name, " = ", value);}
        variables[name] = value;
    }

    // The Stack:
    ListItem peek()
    {
        /*
        Just look at the first item, do
        not pop it off.
        */
        return stack[stackPointer-1];
    }
    ListItem pop()
    {
        debug {
            stderr.writeln("process.pop");
            stderr.writeln(" stack: ", stack[0..stackPointer]);
            stderr.writeln(" SP: ", stackPointer);
        }
        auto item = stack[--stackPointer];
        return item;
    }
    Items pop(int count)
    {
        return this.pop(cast(ulong)count);
    }
    Items pop(ulong count)
    {
        debug {
            stderr.writeln("process.pop(", count, ")");
            stderr.writeln(" stack: ", stack[0..stackPointer]);
            stderr.writeln(" SP: ", stackPointer);
        }
        Items items;
        foreach(i; 0..count)
        {
            items ~= pop();
        }
        return items;
    }
    void push(ListItem item)
    {
        debug {stderr.writeln("process.push ", item);}
        stack[stackPointer++] = item;
        debug {stderr.writeln(" stack: ", stack[0..stackPointer]);}
    }
    template push(T)
    {
        void push(T x)
        {
            this.push(new Atom(x));
        }
    }

    // Utilities:
    Process getRoot()
    {
        if (this.scheduler !is null)
        {
            return this;
        }
        else if (this.parent !is null)
        {
            return this.parent.getRoot();
        }
        else
        {
            return null;
        }
    }

    // Debugging information about itself:
    override string toString()
    {
        string s = "Process[" ~ to!string(this.index) ~ "]";
        s ~= "(" ~ program.name ~ "):\n";

        s ~= "STACK:" ~ to!string(stack[0..stackPointer]) ~ "\n";
        foreach(name, value; variables)
        {
            s ~= " " ~ name ~ "=<" ~ to!string(value) ~">\n";
        }

        s ~= "COMMANDS:\n";
        foreach(name; program.commands.byKey)
        {
            s ~= " " ~ name ~ " ";
        }
        s ~= "\n";
        return s;
    }

    // Commands
    CommandHandler getCommand(string name)
    {
        return this.getCommand(name, true);
    }
    CommandHandler getCommand(string name, bool tryGlobal)
    {
        /*
        This codebase is not much inclined to
        *early returns*, but in this case
        that is the option that makes
        more sense.
        */

        CommandHandler* handler;

        // Local command:
        handler = (name in this.program.commands);
        if (handler !is null) return *handler;

        // Global command:
        if (tryGlobal)
        {
            handler = (name in this.program.globalCommands);
            if (handler !is null)
            {
                // Save in "cache":
                this.program.commands[name] = *handler;
                return *handler;
            }
        }

        // Parent:
        if (this.parent !is null)
        {
            auto h = parent.getCommand(name, false);
            if (h !is null)
            {
                this.program.commands[name] = h;
                return h;
            }
        }

        /*
        name: std.math.run
        Prefix: std.math
        Let's try to autoimport!
        */
        bool success = {
            string modulePath = to!string(name.split(".")[0..$-1].join("."));

            // std.io.out
            // = std.io
            if (program.importModule(modulePath)) return true;

            // io.out
            // = std.io as io
            if (program.importModule("std." ~ modulePath, modulePath)) return true;

            // std.math
            // = std.math
            if (program.importModule(name, name)) return true;

            // math
            // = std.math as math
            if (program.importModule("std." ~ name, name)) return true;

            return false;
        }();

        if (success) {
            // We imported the module, but we're not sure if this
            // name actually exists inside it:
            // (Important: do NOT call this method recursively!)
            handler = (name in this.program.commands);
            if (handler is null)
            {
                throw new Exception("Command not found: " ~ name);
            }
        }
        return *handler;
    }

    // Execution
    CommandContext run()
    {
        auto context = CommandContext(this);
        if (this.program is null) {throw new Exception("process.program cannot be null");}
        return this.run(this.program, context);
    }
    CommandContext run(SubProgram subprogram)
    {
        auto context = CommandContext(this);
        return this.run(subprogram, context);
    }
    CommandContext run(SubProgram subprogram, CommandContext context)
    {
        foreach(index, pipeline; subprogram.pipelines)
        {
            context = pipeline.run(context);

            final switch(context.exitCode)
            {
                case ExitCode.Undefined:
                    throw new Exception(to!string(pipeline) ~ " returned Undefined");

                case ExitCode.Proceed:
                    // That is the expected result.
                    // So we just proceed.
                    break;

                // -----------------
                // Proc execution:
                case ExitCode.ReturnSuccess:
                    // ReturnSuccess should keep stopping
                    // processes until properly
                    // handled.
                    return context;

                case ExitCode.Failure:
                    /*
                    Error handling:
                    1- Call **local** procedure `error.handler`, if
                       it exists and analyse ITS exitCode.
                    2- Or, if it doesn't exist, return `context`
                       as we would already do.
                    */
                    CommandHandler* errorHandler = ("error.handler" in subprogram.commands);
                    if (errorHandler !is null)
                    {
                        debug {
                            stderr.writeln("Calling error.handler");
                            stderr.writeln(" context: ", context);
                        }
                        context = (*errorHandler)("error.handler", context);
                        /*
                        errorHandler can simply "rethrow"
                        the Error or even return a new
                        one. That's ok. We aren't
                        trying to do anything
                        much fancy, here.
                        */
                    }
                    /*
                    Wheter we called errorHandler or not,
                    we ARE going to exit the current
                    scope right now. The idea of
                    a errorHandler is NOT to
                    allow continuing in the
                    same scope.
                    */
                    return context;

                // -----------------
                // Loops:
                case ExitCode.Break:
                case ExitCode.Continue:
                    return context;

                // -----------------
                // Pipeline execution:
                case ExitCode.CommandSuccess:
                    throw new Exception(
                        to!string(pipeline) ~ " returned CommandSuccess."
                        ~ " Expected a Proceed exit code."
                    );
            }
            // Each 8 pipelines we yield fiber/thread control:
            if ((index & 0x07) == 0x07) this.scheduler.yield();
        }

        // Returns the context of the last expression:
        return context;
    }
}
