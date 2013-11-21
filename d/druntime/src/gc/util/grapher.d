module gc.util.grapher;

/*
 *  Experimental connection graphing system
 * 
 */
 
version = GCOUT; 
version = TRACK_FN_CONS;

import clib = core.stdc.stdlib;
import core.stdc.stdio;
import gc.proxy;
//import gc.marking;
import gc.util.injector;
import gc.util.freelists;

/+
enum NodeType { NULL, HEAP, FN, GLOB }

struct Node {
    NodeType type;
    Node** connections;
    size_t nconnections;
    //This is a region pointer if it's a heap node
    //otherwise it's a stack/data pointer
    void* ptr;
    size_t visit;
    size_t num, id;
    bool collected, dead;
}
+/

struct FnMap {
    void* fn;
    char* name;
}
__gshared FnMap* fnmap;
__gshared size_t fnmapsz;

/+
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
+/

/+
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
    nodes[nnodes] = Node(type, null, 0, ptr, visits, type == NodeType.HEAP ? heapcount++ : fncount++, idn++, false, false);
    printf("added\n");
    return nnodes++;
}

size_t graph_add_child(NodeType type, void* ptr, size_t parentn) {
    if (!GRAPHER_ENABLED) return 0;
    //nodes = cast(Node*)clib.realloc(nodes, (nnodes + 1) * Node.sizeof);
    nodes[nnodes] = Node(type, null, 0, ptr, visits, type == NodeType.HEAP ? heapcount++ : fncount++, idn++, false, false);
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
+/

/+
void graph_add_bi_connection(Freelist.Region* r1, FrelRegion* r2) {
    if (!GRAPHER_ENABLED) return;
    /*
    Node* parent = &nodes[parentn];
    for (int i=0; i<nnodes; ++i) {
        if (nodes[i].ptr == ptr) {
            if (parent.connections is null)
                parent.connections = cast(Node**)clib.malloc((Node*).sizeof);
            else
                parent.connections = cast(Node**)clib.realloc(parent.connections, (parent.nconnections+1) * (Node*).sizeof);
            parent.connections[parent.nconnections++] = &nodes[i];
            if (nodes[i].connections is null)
                nodes[i].connections = cast(Node**)clib.malloc((Node*).sizeof);
            else
                nodes[i].connections = cast(Node**)clib.realloc(nodes[i].connections, (nodes[i].nconnections+1) * (Node*).sizeof);
            nodes[i].connections[nodes[i].nconnections++] = parent;
            return;
        }
    }
    printf("error!\n");
    */
    
}
+/
/+
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
+/

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


/+
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
        case NodeType.GLOB:
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
+/

version (GCOUT) {
    private __gshared FILE* grapher_out;
    private size_t grapher_out_count;
    private size_t nodeid, fnidbase = size_t.max/4, glbid = size_t.max/2;

    static this() {
        grapher_out = fopen("gcout.gv", "w");
        fprintf(grapher_out, "digraph GC {\n");
        fprintf(grapher_out,"rankdir=\"LR\"\nlabeljust=\"l\"\n");
    }

    static ~this() {
        fprintf(grapher_out, "}\n");
        fclose(grapher_out);
    }
}

/+
void graph_output_dot(Freelist* fl, bool verify=false, bool trim=false) {
    if (!GRAPHER_ENABLED) return;
    graph_determine_dead(verify);
    visits++;
    idn += nnodes+1;
    fprintf(grapher_out, "subgraph cluster_G%lu {\n",grapher_out_count++);
    fprintf(grapher_out, "\tlabel=%lu\n",grapher_out_count);
    if (!verify) fprintf(grapher_out, "\tstyle=\"dashed\"\n");
    for (int i=0; i<nnodes; ++i) {
        grapher_output_dot_node(&nodes[i], verify, trim);
    }
    for (int i=0; i<nnodes; ++i)
        nodes[i].id += nnodes+1;
    fprintf(grapher_out, "}\n");
}

private void grapher_output_dot_node(Node* node, bool verify, bool trim) {
    if (trim && (node.dead || node.collected)) return;
    if (node.visit == visits) return;
    node.visit = visits;
    if (node.type == NodeType.HEAP) {
        if (node.collected)
            fprintf(grapher_out, "\t%lu[label=%lu,style=\"filled\"]\n",node.id,node.num);
        else
            if (node.dead)
                fprintf(grapher_out, "\t%lu[label=%lu,style=\"dashed\"]\n",node.id,node.num);
            else
                fprintf(grapher_out, "\t%lu[label=%lu]\n",node.id,node.num);
    }
    else if (node.type == NodeType.FN) {
        char* name = graph_get_fname(node.ptr);
        if (name is null) name = cast(char*)"\0";
        if (node.collected)
            fprintf(grapher_out, "\t%lu[label=\"%s(%lu)\",shape=triangle,style=\"filled\"]\n",node.id,name,node.num);
        else
            fprintf(grapher_out, "\t%lu[label=\"%s(%lu)\",shape=triangle]\n",node.id,name,node.num);
    } else {
        fprintf(grapher_out, "\t%lu[label=\"G_%lu\",shape=diamond]\n",node.id,node.num);
    }
    if (node.nconnections > 0) {
        fprintf(grapher_out, "\t%lu", node.id);
        fprintf(grapher_out, " -> { ");
        for (int i=0; i<node.nconnections; ++i) {
            if (trim && (node.connections[i].dead || node.connections[i].collected)) continue;
            fprintf(grapher_out, "%lu ", node.connections[i].id);
        }
        if (node.collected) fprintf(grapher_out, "} [style=\"dashed\"]\n");
        else if (verify && node.dead) fprintf(grapher_out, "} [style=\"dotted\"]\n");
        else if (verify && !node.dead) fprintf(grapher_out, "} [style=\"bold\"]\n");
        else fprintf(grapher_out, "}\n");
        for (int i=0; i<node.nconnections; ++i) {
            grapher_output_dot_node(node.connections[i], verify, trim);
        }
    }
}

private void graph_determine_dead(bool verify) {
    printf("determine dead\n");
    //set heap nodes to dead
    for (int i=0; i<nnodes; ++i)
        nodes[i].dead = true;
    //search for live functions
    for (int i=0; i<nnodes; ++i)
        if (nodes[i].type == NodeType.FN)
            graph_set_alive(&nodes[i], verify);
    void*** globs;
    size_t nglobs = injector_scan_globals(&globs);
    for (int i=0; i<nglobs; ++i) {
        size_t n = graph_add_or_get(NodeType.GLOB, globs[i]);
        nodes[n].dead = false;
        if (nodes[n].connections is null) nodes[n].connections = cast(Node**)clib.malloc((Node*).sizeof);
        nodes[n].connections[0] = &nodes[graph_add_or_get(NodeType.HEAP, *(globs[i]))];
        nodes[n].nconnections = 1;
        graph_set_alive(nodes[n].connections[0], verify);
    }
}

private void graph_set_alive(Node* node, bool verify) {
    if (node.collected) return;
    if (!node.dead) return;
    node.dead = false;
    printf("node %p is not dead\n",node);
    if (verify) {
        if (node.type == NodeType.HEAP) {
            clib.free(node.connections);
            node.nconnections = 0;
            size_t sz = _gc.primaryFL.size(node.ptr);
            printf("sz = %lu\n",sz);
            node.connections = cast(Node**)clib.malloc(sz/8);
            for (void** ptr=cast(void**)node.ptr; ptr<(node.ptr+sz); ++ptr) {
                printf("%p\n",*ptr);
                if (potentialPointer(*ptr)) printf("found potential pointer: %p\n",*ptr);
                if (potentialPointer(*ptr) && _gc.primaryFL.regionOf(*ptr) !is null) {
                    node.connections[node.nconnections++] = &nodes[graph_add_or_get(NodeType.HEAP, *ptr)];
                }
            }
        }
    }
    for (int i=0; i<node.nconnections; ++i)
        graph_set_alive(node.connections[i], verify);
}
+/

version (GCOUT) {
    void graph_output_dot(InjectorData* fnhead, Freelist* fl, InjectorData* deadhead = null) {
        printf("begin\n");
        fprintf(grapher_out, "subgraph cluster_G%lu {\n",grapher_out_count++);
        Freelist.Region** visited;
        size_t nvisited;
        InjectorData* idata = fnhead;
        size_t n = 0;
        while (idata !is null) {
            char* name = graph_get_fname(idata.return_ptr);
            if (name is null)
                fprintf(grapher_out,"%lu[label=\"%p\",shape=triangle]\n",idata.id+fnidbase,idata.return_ptr);
            else
                fprintf(grapher_out,"%lu[label=\"%s\",shape=triangle]\n",idata.id+fnidbase,name);
            fprintf(grapher_out,"%lu -> { ",idata.id+fnidbase);
            for (int i=0; i<idata.npayloads; ++i) {
                fprintf(grapher_out,"%lu ",nodeid+fl.regionID(idata.payload[i]));
            }
            fprintf(grapher_out,"}\n");
            version (TRACK_FN_CONS) if (idata.caller !is null) fprintf(grapher_out,"%lu -> %lu\n",idata.caller.id+fnidbase,idata.id+fnidbase);
            for (int i=0; i<idata.npayloads; ++i) {
                graph_output_node(idata.payload[i], fl, &visited, &nvisited);
            }
            idata = idata.prev;
        }
        idata = deadhead;
        while (idata !is null) {
            char* name = graph_get_fname(idata.return_ptr);
            if (name is null)
                fprintf(grapher_out,"%lu[label=\"%p\",shape=triangle,style=filled]\n",idata.id+fnidbase,idata.return_ptr);
            else
                fprintf(grapher_out,"%lu[label=\"%s\",shape=triangle,style=filled]\n",idata.id+fnidbase,name);
            fprintf(grapher_out,"%lu -> { ",idata.id+fnidbase);
            for (int i=0; i<idata.npayloads; ++i) {
                fprintf(grapher_out,"%lu ",nodeid+fl.regionID(idata.payload[i]));
            }
            fprintf(grapher_out,"}\n");
            version (TRACK_FN_CONS) if (idata.caller !is null) fprintf(grapher_out,"%lu -> %lu\n",idata.caller.id+fnidbase,idata.id+fnidbase);
            for (int i=0; i<idata.npayloads; ++i) {
                graph_output_node(idata.payload[i], fl, &visited, &nvisited);
            }
            idata = idata.prev;
        }
        Freelist.Region** globs;
        size_t nglobs = injector_scan_globals(&globs);
        for (int i=0; i<nglobs; ++i) {
            fprintf(grapher_out,"%lu[label=\"G\",shape=diamond]\n",++glbid);
            fprintf(grapher_out,"%lu -> { %lu }\n",glbid,nodeid+fl.regionID(globs[i]));
            graph_output_node(globs[i], fl, &visited, &nvisited);
        }
        fprintf(grapher_out, "}\n");
        nodeid += fl.numRegions;
        fnidbase += fnidnum;
        printf("done\n");
    }

    private void graph_output_node(Freelist.Region* r, Freelist* fl, Freelist.Region*** visited, size_t* nvisited) {
        for (int i=0; i<*nvisited; ++i) {
            if ((*visited)[i] == r) return;
        }
        if (*visited is null) *visited = cast(Freelist.Region**)clib.malloc((Freelist.Region*).sizeof);
        else *visited = cast(Freelist.Region**)clib.realloc(*visited, (*nvisited+1) * (Freelist.Region*).sizeof);
        (*visited)[(*nvisited)++] = r;
        if (r.size == 0) {
            fprintf(grapher_out, "%lu[label=\"(nil)\",shape=none]\n",nodeid+fl.regionID(r));
        } else if (r.fake_free) {
            fprintf(grapher_out, "%lu[label=\"%p\",style=filled]\n",nodeid+fl.regionID(r),r.ptr);
        } else if (r.color == _gc.epoch % 3) {
            fprintf(grapher_out,"%lu[label=\"%p\"]\n",nodeid+fl.regionID(r),r.ptr);
        } else if (r.color == (_gc.epoch-1) % 3) {
            fprintf(grapher_out,"%lu[label=\"%p\",style=dashed]\n",nodeid+fl.regionID(r),r.ptr);
        } else {
            fprintf(grapher_out,"%lu[label=\"%p\",style=dotted]\n",nodeid+fl.regionID(r),r.ptr);
        }
        fprintf(grapher_out, "%lu -> { ",nodeid+fl.regionID(r));
        for (int i=0; i<r.nconnections; ++i) {
            fprintf(grapher_out, "%lu ", nodeid+fl.regionID(r.connections[i]));
        }
        fprintf(grapher_out, "}\n");
        for (int i=0; i<r.nconnections; ++i) {
            graph_output_node(r.connections[i], fl, visited, nvisited);
        }
    }
}
