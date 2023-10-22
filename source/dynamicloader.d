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

    template functionStore(alias func) {
        __gshared void* functionStore;
    }
}

struct AlternateName {
    string name;
}

mixin template bindFunction(alias symbol, alias functionLoader) {
    alias lib = getUDAs!(symbol, LibImport)[0];

    alias FunctionType = typeof(&symbol);
    enum mangledName = symbol.mangleof;

    alias loadedFunction = LibImport.functionStore!symbol;

    pragma(mangle, mangledName)
    extern (C) auto impl(Parameters!symbol params) @(__traits(getAttributes, symbol)) {
        if (!LibImport.loaded!lib) {
            LibImport.load!lib();
            functionLoader();
        }

        return (cast(FunctionType) loadedFunction)(params);
    }
}

template loadFunction(alias symbol) {
    alias lib = getUDAs!(symbol, LibImport)[0];
    import std.traits: getUDAs, getSymbolsByUDA, ReturnType, Parameters;
    import core.sys.posix.dlfcn;
    import core.sys.windows.windows;

    import std.algorithm.iteration;
    import std.array;
    import std.format;
    enum alternateNames = (cast(AlternateName[]) [getUDAs!(symbol, AlternateName)]).map!((alternateName) => alternateName.name).array();

    alias FunctionType = typeof(&symbol);
    enum mangledName = symbol.mangleof;

    alias loadedFunction = LibImport.functionStore!symbol;

    void loadFunction() {
        alias loadedFunction = LibImport.functionStore!symbol;

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

mixin template makeBindings() {
    import std.traits: getUDAs, getSymbolsByUDA, ReturnType, Parameters;
    import core.sys.posix.dlfcn;
    import core.sys.windows.windows;

    import std.algorithm.iteration;
    import std.array;
    import std.format;
    alias module_ = __traits(parent, {});
    static foreach (symbol; getSymbolsByUDA!(module_, LibImport)) {
        static if (is(typeof(symbol) == function)) {
            mixin bindFunction!(symbol, loadFunctions); // static foreach doesn't introduce a scope but mixin does so we use a mixin.
        }
    }

    void loadFunctions() {
        static foreach (symbol; getSymbolsByUDA!(module_, LibImport)) {
            static if (is(typeof(symbol) == function)) {
                loadFunction!symbol();
            }
        }
    }
}

class LibraryLoadingException: Exception {
    this(string message, string file = __FILE__, size_t line = __LINE__) {
        super(message, file, line);
    }
}
