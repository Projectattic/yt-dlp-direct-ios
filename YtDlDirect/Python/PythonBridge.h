// Plain C interface to the embedded Python interpreter (see PythonBridge.c).
#ifndef PythonBridge_h
#define PythonBridge_h

/// Starts Python with the given home (the bundle's `python` folder).
/// Returns 0 on success. Call once.
int ytdl_python_initialize(const char *python_home);

/// Runs Python source code, holding the GIL for the duration. Returns 0 on success.
int ytdl_python_run(const char *code);

#endif
