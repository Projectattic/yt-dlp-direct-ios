// Embedded-Python setup, following CPython's iOS guide and the BeeWare testbed.
#include <Python/Python.h>
#include "PythonBridge.h"

int ytdl_python_initialize(const char *python_home) {
    PyStatus status;
    PyPreConfig preconfig;
    PyConfig config;
    wchar_t *wide_home;

    PyPreConfig_InitIsolatedConfig(&preconfig);
    PyConfig_InitIsolatedConfig(&config);

    preconfig.utf8_mode = 1;
    config.use_system_logger = 1;
    config.buffered_stdio = 0;
    config.write_bytecode = 0;
    config.install_signal_handlers = 1;

    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) {
        PyConfig_Clear(&config);
        return 1;
    }

    wide_home = Py_DecodeLocale(python_home, NULL);
    status = PyConfig_SetString(&config, &config.home, wide_home);
    PyMem_RawFree(wide_home);
    if (PyStatus_Exception(status)) {
        PyConfig_Clear(&config);
        return 2;
    }

    status = PyConfig_Read(&config);
    if (PyStatus_Exception(status)) {
        PyConfig_Clear(&config);
        return 3;
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        return 4;
    }

    // Release the GIL so worker threads can take it with PyGILState_Ensure.
    PyEval_SaveThread();
    return 0;
}

int ytdl_python_run(const char *code) {
    PyGILState_STATE gil = PyGILState_Ensure();
    int rc = PyRun_SimpleString(code);
    PyGILState_Release(gil);
    return rc;
}
