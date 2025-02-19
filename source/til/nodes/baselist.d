module til.nodes.baselist;

import til.nodes;


class BaseList : ListItem
{
    Items items;

    this()
    {
        this([]);
    }
    this(ListItem item)
    {
        this([item]);
    }
    this(Items items)
    {
        this.items = items;
    }

    // Operators:
    template opUnary(string operator)
    {
        override ListItem opUnary()
        {
            throw new Exception("Cannot apply " ~ operator ~ " to a List!");
        }
    }
}

