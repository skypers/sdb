module sdb;

import std.algorithm : countUntil, reduce, startsWith;
import std.array : array, replace, splitter;
import std.ascii : whitespace;
import std.file : dirEntries, FileException, isDir, isFile, SpanMode, SysTime, timeLastModified;
import std.process : shell;
import std.stdio : File, lines, writeln, writefln;
import std.string : chomp, strip;


int main(string[] args) {
    return dispatch_args(args[1 .. $]);
}

int dispatch_args(string[] args) {
    auto conf = new configuration(".sdb");

    foreach (a; args) {
        switch (a) {
            case "build" :
                writefln("building '%s'", conf.out_name);
                auto comp = new compiler(conf);
                comp.compile(false);
                break;

            case "test" :
                auto comp = new compiler(conf);
                comp.compile(true);
                break;

            case "clean" :
                break;

            case "install" :
                break;

            case "uninstall" :
                break;

            default :
                writefln("usage: " ~ args[0] ~ " [build|test|clean]");
        }
    }

    return 0;
}


enum build_type  { DEBUG, RELEASE };
enum target_type { EXEC, STATIC, SHARED };

final class configuration {
    enum DEFAULT_FILE = ".sdb";

    private {
        alias void delegate(string[]) token_fun_t;
        token_fun_t[string] _tokenFunTbl;
        build_type _bt;
        target_type _tt;
        string[] _libDirs;
        string[] _libs;
        string[] _importDirs;
        string[] _srcDirs;
        string[] _testDirs;
        string _outName;
    }

    @property {
        build_type bt() const {
            return _bt;
        }

        target_type tt() const {
            return _tt;
        }

        auto lib_dirs() const {
            return _libDirs;
        }

        auto libs() const {
            return _libs;
        }

        auto import_dirs() const {
            return _importDirs;
        }

        auto src_dirs() const {
            return _srcDirs;
        }

        auto test_dirs() const {
            return _testDirs;
        }

        auto out_name() const {
            return _outName;
        }
    }

    this(string file) in {
        assert ( file !is null );
    } body {
        default_();
        init_fun_();

        if (!file.isFile) {
            if (file == DEFAULT_FILE)
                throw new FileException(file, "unable to open file");
            load_(DEFAULT_FILE);
        } else {
            load_(file);
        }
    }

    private void default_() {
        _bt = build_type.DEBUG;
        _tt = target_type.EXEC;
    }

    private void init_fun_() {
        _tokenFunTbl = [
            "BUILD" : &build_,
            "TARGET" : &target_,
            "LIB_DIR" : &values_!"libDirs",
            "LIB" : &values_!"libs",
            "IMPORT_DIR" : &values_!"importDirs",
            "SRC_DIR" : &values_!"srcDirs",
            "TEST_DIR" : &values_!"testDirs",
            "OUT_NAME" : &values_!"outName"
        ];
    }

    private void load_(string file) {
        auto fh = File(file, "r");

        if (!fh.isOpen)
            throw new FileException(file, "file is not opened");

        writefln("reading configuration from file '" ~ file ~ "'");
        foreach (ulong i, string line; lines(fh)) {
            auto str = strip(line);
            auto tokens = array(splitter(str));

            if (tokens.length >= 2) {
                /* tokens[0] is the variable type, tokens[1..$] the values */
                auto varType = tokens[0];
                writefln("reading variable '%s'", varType);
                _tokenFunTbl[tokens[0]](tokens[1..$]);
            } else {
                writefln("incorrect line syntax (%d tokens): L%d: %s", tokens.length, i, str);
            }
        }

        check_dirs_();
    }

    private void check_dirs_() {
        void foreach_check_(string a)() {
            mixin("foreach (ref d; " ~ a ~ ")
                    d = check_file_prefix_(d);");
        }

        foreach_check_!"_libDirs"();
        foreach_check_!"_importDirs"();
        foreach_check_!"_srcDirs"();
        foreach_check_!"_testDirs"();
    }

    private string check_file_prefix_(string file) {
        if (startsWith(file, '.', '/') == 0)
            file = "./" ~ file;
        return file;
    }

    private void build_(string[] values) {
        if (values.length == 1) {
            switch (values[0]) {
                case "debug" :
                    _bt = build_type.DEBUG;
                    break;

                case "release" :
                    _bt = build_type.RELEASE;
                    break;

                default :
                    writefln("warning: '%s' is not a correct build type", values[0]);
            }
        } 
    }

    private void target_(string[] values) {
        if (values.length == 1) {
            switch (values[0]) {
                case "exec" :
                    _tt = target_type.EXEC;
                    break;

                case "static" :
                    _tt = target_type.STATIC;
                    break;

                case "shared" :
                    _tt = target_type.SHARED;
                    break;

                default :
                    writefln("warning: '%s' is not a correct target type", values[0]);
            }
        }
    }

    private void values_(string token)(string[] values) {
        mixin("auto r = &_" ~ token ~ ";");
        static if (token == "outName")
            *r = values[0];
        else
            *r = values;
    }
}

final class compiler {
    version(DigitalMars) {
        enum compiler_str   = "dmd ";
        enum object_str     = "-c ";
        enum lib_dir_str    = "-L-L";
        enum lib_str        = "-L-l";
        enum import_dir_str = "-I";
        enum out_str        = "-of";
    }

    private configuration _conf;

    this(configuration conf) {
        _conf = conf;
    }

    void compile(bool test) {
        string bt;
        final switch (_conf.bt) {
            case build_type.DEBUG :
                bt = "-debug -g";
                break;

            case build_type.RELEASE :
                bt = "-release -O";
                break;
        }
		auto importDirs = _conf.import_dirs;
        auto cmd = compiler_str
            ~ object_str
            ~ bt ~ " "
            ~ (importDirs.length ? reduce!("a ~ \"" ~ import_dir_str ~ "\"~b ")(import_dir_str, importDirs) : "")
            ~ out_str;

        foreach (string path; test ? _conf.test_dirs : _conf.src_dirs) {
            try {
                path.isDir;;
            } catch (FileException e) {
                writefln("warning: %s", e.msg);
                continue; /* FIXME: a bit dirty imho */
            } 

            auto files = array(dirEntries(path, "*.d", SpanMode.depth));
			auto filesNb = files.length;
            foreach (int i, string file; files) {
                auto m = module_from_file_(file);
				if (timeLastModified(file) >= timeLastModified(m, SysTime.min)) {
					writefln("--> [%4d%% | Compiling %s ]", cast(int)(((i+1)*100/filesNb)), m);
					auto r = shell(cmd ~ m ~ " " ~ file);
					if (r.length > 1)
						writeln(cmd ~ m ~ " " ~ file ~ '\n');
				}
            }
        }
    }

    private string module_from_file_(string file) in {
        assert ( file !is null );
    } body {
		auto startIndex = countUntil!"a != '.' && a != '/'"(file);
		auto m = chomp(file[startIndex .. $], "/");
		m = replace(m, "/", ".");
        return m[0 .. $-2] ~ ".o";
    }

    /*
    void link() {
        auto cmd = compiler_str
            ~ _conf.target ~ " "
            ~ _conf.build_type ~ " "
            ~ reduce!("a ~ " ~ lib_dir_str ~ "b")(lib_dir_str, _conf.lib_dirs) ~ " "
            ~ reduce!("a ~ " ~ lib_str ~ "b")(lib_str, _conf.libs) ~ " "
            ~ out_dir ~ _conf.out_name;
        shell(cmd);
    }
    */
}
