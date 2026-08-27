# logger_binding_unittest.py — BUG0043 unbound module logger
#
# `function.py` used to bind `log = logging.getLogger("function")` separately
# inside each function that needed it. A function that forgot still imported,
# compiled and passed --dry-run; it raised NameError the first time it reached a
# log line on a real run. That is what killed a 10-cycle power_cycle run at
# cycle 1, inside the FWK037 inventory step.
#
# py_compile cannot catch this and neither can a dry run that never enters the
# branch. So: scan every module for a `log` that is read but never bound, and
# exercise the two functions that actually crashed.
#
# Run:
#   python3 -m unittest logger_binding_unittest -v
#   (from src/python/)

import ast
import logging
import pathlib
import unittest

import function

HERE = pathlib.Path(__file__).resolve().parent


def unbound_reads(path, watch=("log",)):
    """Return [(function_name, lineno, name)] for names read but never bound.

    Approximate on purpose -- it models the binding rules that matter here
    (module-level assignments and imports, parameters, any Store in the
    function, nested defs) rather than reimplementing a full scope analyser.
    """
    tree = ast.parse(pathlib.Path(path).read_text(encoding="utf-8"))

    module_bound = set()
    for node in tree.body:
        if isinstance(node, ast.Assign):
            module_bound.update(t.id for t in node.targets if isinstance(t, ast.Name))
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            module_bound.update((a.asname or a.name).split(".")[0] for a in node.names)

    hits = []

    class Visitor(ast.NodeVisitor):
        def __init__(self, bound):
            self.bound = bound

        def visit_FunctionDef(self, fn):
            bound = set(self.bound)
            bound.update(a.arg for a in fn.args.args + fn.args.kwonlyargs)
            if fn.args.vararg:
                bound.add(fn.args.vararg.arg)
            if fn.args.kwarg:
                bound.add(fn.args.kwarg.arg)
            for n in ast.walk(fn):
                if isinstance(n, ast.Name) and isinstance(n.ctx, ast.Store):
                    bound.add(n.id)
                elif isinstance(n, (ast.Import, ast.ImportFrom)):
                    bound.update((a.asname or a.name).split(".")[0] for a in n.names)
                elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n is not fn:
                    bound.add(n.name)
            for n in ast.walk(fn):
                if (isinstance(n, ast.Name) and isinstance(n.ctx, ast.Load)
                        and n.id in watch and n.id not in bound):
                    hits.append((fn.name, n.lineno, n.id))
            Visitor(bound).generic_visit(fn)

        visit_AsyncFunctionDef = visit_FunctionDef

    Visitor(module_bound).visit(tree)
    return hits


class LoggerBindingTest(unittest.TestCase):

    def test_no_module_uses_an_unbound_logger(self):
        problems = []
        for path in sorted(HERE.glob("*.py")):
            for fn, line, name in unbound_reads(path):
                problems.append(f"{path.name}:{line}: '{name}' read in {fn}() but never bound")
        self.assertEqual(problems, [], "\n".join(problems))

    def test_function_module_has_a_module_level_logger(self):
        self.assertIsInstance(function.log, logging.Logger)
        self.assertEqual(function.log.name, "function")


class Fwk037LoggingTest(unittest.TestCase):
    """The two call sites that actually raised NameError on the DUT."""

    def setUp(self):
        logging.disable(logging.CRITICAL)
        self.addCleanup(logging.disable, logging.NOTSET)

    def test_log_system_info_runs(self):
        function.log_system_info({
            "hostname": "dut1", "os": "Windows 11",
            "product": "P", "baseboard": "B", "bios_version": "1.2",
            "cpu_model": "i7", "cpu_sockets": 1, "cpu_logical": 16,
            "memory": {"installed_bytes": 192 * 1024 ** 3,
                       "usable_bytes": 128 * 1024 ** 3,
                       "dimm_populated_count": 6,
                       "result": "Fail", "reason": "2 DIMMs not trained"},
        })

    def test_log_system_info_tolerates_empty_and_partial_input(self):
        function.log_system_info({})
        function.log_system_info(None)
        function.log_system_info({"hostname": "dut1"})     # everything else missing

    def test_collect_system_info_error_path_logs_instead_of_raising(self):
        """The `except Exception` handler logs — it must not raise NameError and
        turn a benign inventory failure into a crashed test."""
        self.assertIsNotNone(function.collect_system_info("", 22, ""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
