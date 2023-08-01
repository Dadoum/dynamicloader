module dynamicloader;

import core.stdc.stdlib;
import core.sys.posix.dlfcn;
import core.sys.windows.windows;

import std.format;
import std.stdio;

public struct LibImport {
    private string[] libraries;

    this(string[] libraryNames...) { libraries = libraryNames; }

    template libraryHandle(LibImport library) {
        __gshared static void* libraryHandle;

        shared static this() {
            static foreach (libraryName; library.libraries) {
                version (Windows) {
                    libraryHandle = LoadLibraryA(libraryName);
                } else {
                    libraryHandle = dlopen(libraryName, RTLD_LAZY);
                }
                if (libraryHandle) {
                    return;
                }
            }
            stderr.writeln(format!"Cannot load any of the following libraries: %s"(library.libraries));
            abort();
        }

        shared static ~this()
        {
            version (Windows) {
                FreeLibrary(libraryHandle);
            } else {
                dlclose(libraryHandle);
            }
        }
    }
}

struct AlternateName {
    string name;
}

mixin template bindFunction(alias symbol) {
    import core.sys.posix.dlfcn;
    import core.sys.windows.windows;

    import std.algorithm.iteration;
    import std.array;

    alias lib = getUDAs!(symbol, LibImport)[0];
    enum alternateNames = (cast(AlternateName[]) [getUDAs!(symbol, AlternateName)]).map!((alternateName) => alternateName.name).array();

    alias FunctionType = typeof(&symbol);
    enum mangledName = symbol.mangleof;

    __gshared void* loadedFunction;

    pragma(mangle, mangledName)
    extern (C) ReturnType!symbol impl(Parameters!symbol params) @(__traits(getAttributes, symbol)) {
        if (!loadedFunction) {
            auto library = LibImport.libraryHandle!lib;
            assert(library != null);

            static foreach (name; alternateNames ~ mangledName) {
                version (Windows) {
                    loadedFunction = GetProcAddress(library, mangledName);
                } else {
                    loadedFunction = dlsym(library, mangledName);
                }
            }
        }
        return (cast(FunctionType) loadedFunction)(params);
    }
}

mixin template makeBindings() {
    import std.traits: getUDAs, getSymbolsByUDA, ReturnType, Parameters;
    static foreach (symbol; getSymbolsByUDA!(__traits(parent, {}), LibImport)) {
        static if (is(typeof(symbol) == function)) {
            mixin bindFunction!(symbol); // static foreach doesn't introduce a scope but mixin does so we use a mixin.
        }
    }
}