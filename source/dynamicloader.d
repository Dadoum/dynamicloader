module dynamicloader;

import core.sys.posix.dlfcn;
import core.sys.windows.windows;

import std.format;
import std.stdio;

public struct LibImport {
    private string[] libraries;

    this(string[] libraryNames...) { libraries = libraryNames; }

    alias libraryHandle(LibImport library) = lhStore!library.libraryHandle;
    alias load(LibImport library) = lhStore!library.load;
    alias loaded(LibImport library) = lhStore!library.loaded;

    template lhStore(LibImport library) {
        __gshared static void* libraryHandle;
        static shared bool loaded = false;

        static void load() {
            static foreach (libraryName; library.libraries) {
                version (Windows) {
                    libraryHandle = LoadLibraryA(libraryName);
                } else {
                    libraryHandle = dlopen(libraryName, RTLD_LAZY);
                }
                if (libraryHandle) {
                    loaded = true;
                    return;
                }
            }
            throw new LibraryLoadingException(format!"Cannot load any of the following libraries: %s"(library.libraries));
        }

        // shared static ~this()
        // {
        //     version (Windows) {
        //         FreeLibrary(libraryHandle);
        //     } else {
        //         dlclose(libraryHandle);
        //     }
        // }
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
    import std.format;

    alias lib = getUDAs!(symbol, LibImport)[0];
    enum alternateNames = (cast(AlternateName[]) [getUDAs!(symbol, AlternateName)]).map!((alternateName) => alternateName.name).array();

    alias FunctionType = typeof(&symbol);
    enum mangledName = symbol.mangleof;

    __gshared void* loadedFunction;

    void ensureFunctionIsLoaded() {
        if (!LibImport.loaded!lib) {
            LibImport.load!lib();
        }

        if (!loadedFunction) {
            auto library = LibImport.libraryHandle!lib;
            assert(library != null);

            static foreach (name; alternateNames ~ mangledName) {
                version (Windows) {
                    loadedFunction = GetProcAddress(library, name);
                } else {
                    loadedFunction = dlsym(library, name);
                }
                if (loadedFunction) {
                    return;
                }
            }
            throw new LibraryLoadingException(format!"Cannot load %s, tried to load %s"(__traits(identifier, symbol), alternateNames ~ mangledName));
        }
    }

    pragma(mangle, mangledName)
    extern (C) ReturnType!symbol impl(Parameters!symbol params) @(__traits(getAttributes, symbol)) {
        ensureFunctionIsLoaded();
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

class LibraryLoadingException: Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}
