module gc.grapher;

/*
 *  Experimental connection graphing system
 * 
 */
 
import clib = core.stdc.stdlib;
import core.stdc.stdio;

enum NodeType { NULL, HEAP, FN, TLS }

struct Node {
    NodeType type;
    Node** connections;
    size_t nconnections;
    //This is a region pointer if it's a heap node
    //otherwise it's a stack/data pointer
    void* ptr;
    size_t visit;
    size_t num, id;
    bool collected;
}

struct FnMap {
    void* fn;
    char* name;
}

//__gshared Node* nodes = null;
__gshared Node[512] nodes;
__gshared size_t nnodes = 0;
__gshared size_t visits = 0;
__gshared size_t heapcount = 0;
__gshared size_t fncount = 0;
__gshared size_t idn = 0;

__gshared bool GRAPHER_ENABLED = false;
__gshared FnMap* fnmap;
__gshared size_t fnmapsz;

size_t graph_add_or_get(NodeType type, void* ptr) {
    if (!GRAPHER_ENABLED) return 0;
    for (int i=0; i<nnodes; ++i) {
        if (nodes[i].ptr == ptr) {
            return i;
        }
    }
    //if (nodes is null)
    //    nodes = cast(Node*)clib.malloc(Node.sizeof);
    //else
    //    nodes = cast(Node*)clib.realloc(nodes, (nnodes + 1) * Node.sizeof);
    nodes[nnodes] = Node(type, null, 0, ptr, visits, type == NodeType.HEAP ? heapcount++ : fncount++, idn++, false);
    return nnodes++;
}

size_t graph_add_child(NodeType type, void* ptr, size_t parentn) {
    if (!GRAPHER_ENABLED) return 0;
    //nodes = cast(Node*)clib.realloc(nodes, (nnodes + 1) * Node.sizeof);
    nodes[nnodes] = Node(type, null, 0, ptr, visits, type == NodeType.HEAP ? heapcount++ : fncount++, idn++, false);
    Node* parent = &nodes[parentn];
    if (parent.connections is null)
        parent.connections = cast(Node**)clib.malloc((Node*).sizeof);
    else
        parent.connections = cast(Node**)clib.realloc(parent.connections, (parent.nconnections + 1) * (Node*).sizeof);
    parent.connections[parent.nconnections++] = &nodes[nnodes];
    return nnodes++;
}

void graph_add_connection(size_t parentn, void* ptr) {
    if (!GRAPHER_ENABLED) return;
    Node* parent = &nodes[parentn];
    for (int i=0; i<nnodes; ++i) {
        if (nodes[i].ptr == ptr) {
            if (parent.connections is null)
                parent.connections = cast(Node**)clib.malloc((Node*).sizeof);
            else
                parent.connections = cast(Node**)clib.realloc(parent.connections, (parent.nconnections+1) * (Node*).sizeof);
            parent.connections[parent.nconnections++] = &nodes[i];
            return;
        }
    }
    printf("error!\n");
}

//remove the node, detaching all children
void graph_disown(void* ptr) {
    if (!GRAPHER_ENABLED) return;
    for (int i=0; i<nnodes; ++i) {
        if (nodes[i].ptr == ptr) {
            nodes[i].collected = true;
            return;
        }
    }
}

void graph_add_fname(string name = __FUNCTION__) {
    char* nameptr = cast(char*)name;
    if (fnmap is null)
        fnmap = cast(FnMap*)clib.malloc(FnMap.sizeof);
    else
        fnmap = cast(FnMap*)clib.realloc(fnmap, (fnmapsz+1) * FnMap.sizeof);
    fnmap[fnmapsz] = FnMap(graph_get_fptr_up(), nameptr);
    fnmapsz++;
}

char* graph_get_fname(void* fptr) {
    //printf("fptr = %p\n",fptr);
    for (int i=0; i<fnmapsz; ++i) {
        //printf("%p\n",fnmap[i].fn);
        if (fnmap[i].fn == fptr) {
            //printf("match found\n");
            return fnmap[i].name;
        }
    }
    return null;
}

private void* graph_get_fptr_up() {
    asm {
        naked;
        mov RAX, [RBP];
        mov RAX, [RAX+8];
        ret;
    }
}

/*
 *  Print the graph to stdio
 */
void print_graph() {
    if (!GRAPHER_ENABLED) return;
    printf("+ CONNECTIVITY GRAPH\n");
    visits++;
    for (int i=0; i<nnodes; ++i) {
        if (nodes[i].visit != visits && nodes[i].type != NodeType.NULL) {
            print_node(&nodes[i], 0);
        }
    }
    printf("+-------------------\n");
}

private void print_node(Node* node, size_t indentation) {
    char* indent = cast(char*)clib.malloc((indentation+10) * char.sizeof);
    for (int i=0; i<indentation; ++i) {
        indent[i] = ' ';
    }
    size_t i = indentation;
    if (node.connections is null && indentation > 0) {
        indent[i .. i+2] = "| ";
        i += 2;
    } else {
        indent[i .. i+3] = "++ ";
        i += 3;
    }
    if (node.type > 3 || node.type < 0) clib.abort();
    final switch (node.type) {
        case NodeType.NULL:
            indent[i .. i+6] = "NULL \0";
        break;
        case NodeType.HEAP:
            indent[i .. i+6] = "HEAP \0";
        break;
        case NodeType.FN:
            indent[i .. i+6] = "FUNC \0";
        break;
        case NodeType.TLS:
            indent[i .. i+6] = "GLOB \0";
        break;
    }
    /*
    printf("%s%s %s %p\n",indent,
        node.connections is null ? "|\0" : "++\0",
        node.type == NodeType.HEAP ? "HEAP\0" :
            (node.type == NodeType.FN ? "FUNC\0" : "GLOB\0"),
        node.ptr);
    */
    printf("%s%p\n",indent,node.ptr);
    if (node.visit != visits) {
        node.visit = visits;
        for (int n=0; n<node.nconnections; ++n) {
            print_node(node.connections[n], indentation+1);
        }
    }
    clib.free(indent);
}

private __gshared FILE* grapher_out;
private size_t grapher_out_count;

static this() {
    grapher_out = fopen("gcout.gv", "w");
    fprintf(grapher_out, "digraph GC {\n");
    fprintf(grapher_out,"rankdir=\"LR\"\nlabeljust=\"l\"\n");
}

static ~this() {
    fprintf(grapher_out, "}\n");
    fclose(grapher_out);
}


void graph_output_dot() {
    if (!GRAPHER_ENABLED) return;
    visits++;
    idn += nnodes+1;
    fprintf(grapher_out, "subgraph cluster_G%lu {\n",grapher_out_count++);
    fprintf(grapher_out, "\tlabel=%lu\n",grapher_out_count);
    for (int i=0; i<nnodes; ++i) {
        grapher_output_dot_node(&nodes[i]);
    }
    for (int i=0; i<nnodes; ++i)
        nodes[i].id += nnodes+1;
    fprintf(grapher_out, "}\n");
}

private void grapher_output_dot_node(Node* node) {
    if (node.visit == visits) return;
    node.visit = visits;
    if (node.type == NodeType.HEAP) {
        if (node.collected)
            fprintf(grapher_out, "\t%lu[label=%lu,style=\"filled\"]\n",node.id,node.num);
        else
            fprintf(grapher_out, "\t%lu[label=%lu]\n",node.id,node.num);
    }
    else {
        char* name = graph_get_fname(node.ptr);
        if (name is null) name = cast(char*)"\0";
        if (node.collected)
            fprintf(grapher_out, "\t%lu[label=\"%s(%lu)\",shape=triangle,style=\"filled\"]\n",node.id,name,node.num);
        else
            fprintf(grapher_out, "\t%lu[label=\"%s(%lu)\",shape=triangle]\n",node.id,name,node.num);
    }
    fprintf(grapher_out, "\t%lu", node.id);
    if (node.nconnections > 0) {
        fprintf(grapher_out, " -> { ");
        for (int i=0; i<node.nconnections; ++i) {
            fprintf(grapher_out, "%lu ", node.connections[i].id);
        }
        fprintf(grapher_out, "}\n");
        for (int i=0; i<node.nconnections; ++i) {
            grapher_output_dot_node(node.connections[i]);
        }
    } else 
        fprintf(grapher_out,"\n");
}
