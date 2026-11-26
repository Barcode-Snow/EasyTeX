// EasyTeX editor glue: Monaco + a small LaTeX language, driven from Swift.
// Swift -> JS:  window.easytex.<method>(...)
// JS -> Swift:  webkit.messageHandlers.easytex.postMessage({type, ...})
(function () {
  'use strict';

  var post = function (msg) { window.webkit.messageHandlers.easytex.postMessage(msg); };

  self.MonacoEnvironment = {
    getWorker: function () {
      return new Worker('vs/assets/editor.worker.js', { type: 'module' });
    }
  };

  require.config({ paths: { vs: 'vs' } });
  // 'vs/editor' is Monaco's core API; the second module registers the standard editor features
  // (find widget, suggest, multi-cursor, ...). Both names are pinned to the vendored monaco-editor 0.58.0.
  require(['vs/editor', 'vs/toggleHighContrast-CmI6H2gJ'], function (monaco) {

    // ---------- LaTeX language ----------
    monaco.languages.register({ id: 'latex' });
    monaco.languages.register({ id: 'bibtex' });

    monaco.languages.setLanguageConfiguration('latex', {
      comments: { lineComment: '%' },
      brackets: [['{', '}'], ['[', ']'], ['(', ')']],
      autoClosingPairs: [
        { open: '{', close: '}' }, { open: '[', close: ']' }, { open: '(', close: ')' },
        { open: '$', close: '$', notIn: ['comment'] }
      ],
      surroundingPairs: [
        { open: '{', close: '}' }, { open: '[', close: ']' }, { open: '(', close: ')' }, { open: '$', close: '$' }
      ],
      wordPattern: /\\?[A-Za-z@]+\*?|\d+/
    });

    monaco.languages.setMonarchTokensProvider('latex', {
      tokenizer: {
        root: [
          [/%.*$/, 'comment'],
          [/\\(?:begin|end)(?=\s*\{)/, 'keyword.env'],
          [/\\(?:part|chapter|section|subsection|subsubsection|paragraph|subparagraph)\*?/, 'keyword.section'],
          [/\\[A-Za-z@]+\*?/, 'keyword'],
          [/\\[^A-Za-z@]/, 'keyword'],
          [/\$\$/, { token: 'string.math', next: '@display' }],
          [/\$/, { token: 'string.math', next: '@inline' }],
          [/[{}\[\]]/, 'delimiter.bracket'],
          [/&/, 'operator'],
          [/#\d/, 'variable']
        ],
        inline: [
          [/\\\$/, 'string.math'],
          [/\$/, { token: 'string.math', next: '@pop' }],
          [/%.*$/, 'comment'],
          [/\\[A-Za-z@]+/, 'keyword'],
          [/[^$\\%]+/, 'string.math'],
          [/./, 'string.math']
        ],
        display: [
          [/\$\$/, { token: 'string.math', next: '@pop' }],
          [/%.*$/, 'comment'],
          [/\\[A-Za-z@]+/, 'keyword'],
          [/[^$\\%]+/, 'string.math'],
          [/./, 'string.math']
        ]
      }
    });

    monaco.languages.setMonarchTokensProvider('bibtex', {
      tokenizer: {
        root: [
          [/%.*$/, 'comment'],
          [/@[A-Za-z]+/, 'keyword.section'],
          [/[A-Za-z][\w:\-\.\/]*(?=\s*=)/, 'keyword'],
          [/"[^"]*"/, 'string.math'],
          [/[{}]/, 'delimiter.bracket']
        ]
      }
    });
    monaco.languages.setLanguageConfiguration('bibtex', {
      brackets: [['{', '}']],
      autoClosingPairs: [{ open: '{', close: '}' }, { open: '"', close: '"' }]
    });

    // ---------- Themes (VS Code Dark+ / Light+ flavoured) ----------
    monaco.editor.defineTheme('easytex-dark', {
      base: 'vs-dark', inherit: true,
      rules: [
        { token: 'comment', foreground: '6A9955' },
        { token: 'keyword', foreground: '569CD6' },
        { token: 'keyword.env', foreground: '4EC9B0' },
        { token: 'keyword.section', foreground: 'C586C0', fontStyle: 'bold' },
        { token: 'string.math', foreground: 'CE9178' },
        { token: 'delimiter.bracket', foreground: 'FFD700' },
        { token: 'variable', foreground: '9CDCFE' },
        { token: 'operator', foreground: 'D4D4D4' }
      ],
      colors: {}
    });
    monaco.editor.defineTheme('easytex-light', {
      base: 'vs', inherit: true,
      rules: [
        { token: 'comment', foreground: '008000' },
        { token: 'keyword', foreground: '0000FF' },
        { token: 'keyword.env', foreground: '267F99' },
        { token: 'keyword.section', foreground: 'AF00DB', fontStyle: 'bold' },
        { token: 'string.math', foreground: 'A31515' },
        { token: 'delimiter.bracket', foreground: '795E26' },
        { token: 'variable', foreground: '001080' }
      ],
      colors: {}
    });

    // ---------- Completions: commands, environments, snippets ----------
    var COMMANDS = ('section subsection subsubsection paragraph chapter part label ref eqref pageref cite citep citet footnote ' +
      'textbf textit texttt textsc emph underline textrm textsf includegraphics caption centering item input include ' +
      'usepackage documentclass title author date maketitle tableofcontents bibliography bibliographystyle printbibliography ' +
      'newcommand renewcommand newenvironment frac sqrt sum prod int lim infty alpha beta gamma delta epsilon theta lambda mu ' +
      'pi sigma phi omega mathbb mathcal mathbf mathrm left right cdot times leq geq neq approx rightarrow Rightarrow ' +
      'hline vspace hspace newpage clearpage noindent href url hyperref textwidth linewidth columnwidth bigskip medskip smallskip ' +
      'newtheorem setlength geometry begin end').split(' ');
    var ENVS = ('document equation align align* itemize enumerate description figure table tabular center abstract ' +
      'theorem lemma proof definition remark verbatim minipage frame block columns cases matrix pmatrix bmatrix tikzpicture lstlisting').split(' ');

    monaco.languages.registerCompletionItemProvider('latex', {
      triggerCharacters: ['\\', '{'],
      provideCompletionItems: function (model, position) {
        var word = model.getWordUntilPosition(position);
        var range = { startLineNumber: position.lineNumber, endLineNumber: position.lineNumber,
                      startColumn: word.startColumn, endColumn: word.endColumn };
        var line = model.getLineContent(position.lineNumber).slice(0, position.column - 1);
        var K = monaco.languages.CompletionItemKind;
        var R = monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet;
        var out = [];
        if (/\\(begin|end)\{[A-Za-z*]*$/.test(line)) {
          ENVS.forEach(function (e) { out.push({ label: e, kind: K.Module, insertText: e, range: range }); });
          return { suggestions: out };
        }
        COMMANDS.forEach(function (c) {
          out.push({ label: '\\' + c, kind: K.Function, insertText: c, range: range });
        });
        var snip = function (label, doc, text) {
          out.push({ label: label, kind: K.Snippet, documentation: doc, insertText: text, insertTextRules: R, range: range });
        };
        snip('begin', 'Environment', 'begin{${1:environment}}\n\t$0\n\\end{${1:environment}}');
        snip('fig', 'Figure', 'begin{figure}[htbp]\n\t\\centering\n\t\\includegraphics[width=0.8\\linewidth]{${1:file}}\n\t\\caption{${2:caption}}\n\t\\label{fig:${3:label}}\n\\end{figure}');
        snip('tab', 'Table', 'begin{table}[htbp]\n\t\\centering\n\t\\begin{tabular}{${1:ll}}\n\t\t\\hline\n\t\t$0\n\t\t\\hline\n\t\\end{tabular}\n\t\\caption{${2:caption}}\n\t\\label{tab:${3:label}}\n\\end{table}');
        snip('eq', 'Equation', 'begin{equation}\n\t$0\n\t\\label{eq:${1:label}}\n\\end{equation}');
        snip('ali', 'Align', 'begin{align}\n\t$0\n\\end{align}');
        snip('item', 'Itemize', 'begin{itemize}\n\t\\item $0\n\\end{itemize}');
        snip('enum', 'Enumerate', 'begin{enumerate}\n\t\\item $0\n\\end{enumerate}');
        snip('frame', 'Beamer frame', 'begin{frame}{${1:title}}\n\t$0\n\\end{frame}');
        return { suggestions: out };
      }
    });

    // ---------- Editor ----------
    var editor = monaco.editor.create(document.getElementById('editor'), {
      model: null,
      theme: 'easytex-light',
      fontFamily: 'Monaco, Menlo, monospace',
      fontSize: 13,
      tabSize: 2,
      insertSpaces: true,
      wordWrap: 'on',
      minimap: { enabled: true },
      automaticLayout: true,
      scrollBeyondLastLine: false,
      renderWhitespace: 'none',
      padding: { top: 8, bottom: 8 },
      smoothScrolling: true,
      wordBasedSuggestions: 'off',
      quickSuggestions: { other: true, comments: false, strings: false },
      links: false,
      contextmenu: true
    });

    var docs = {};       // path -> { model, savedVersion, dirty, view }
    var current = null;
    var idleTimer = null;

    function languageFor(path) {
      var p = path.toLowerCase();
      if (/\.(tex|sty|cls|ltx|dtx)$/.test(p)) return 'latex';
      if (/\.bib$/.test(p)) return 'bibtex';
      return 'plaintext';
    }

    function refreshDirty(path) {
      var d = docs[path]; if (!d) return;
      var isDirty = d.model.getAlternativeVersionId() !== d.savedVersion;
      if (isDirty !== d.dirty) { d.dirty = isDirty; post({ type: 'dirty', path: path, dirty: isDirty }); }
    }

    editor.onDidChangeModelContent(function () {
      if (current) refreshDirty(current);
      clearTimeout(idleTimer);
      idleTimer = setTimeout(function () { post({ type: 'idle' }); }, 3000);
    });

    editor.addCommand(monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyS, function () { post({ type: 'save' }); });

    editor.onDidChangeCursorPosition(function (e) {
      if (current) post({ type: 'cursor', path: current, line: e.position.lineNumber, column: e.position.column });
    });

    window.easytex = {
      open: function (path, text) {
        if (current && docs[current]) docs[current].view = editor.saveViewState();
        var d = docs[path];
        if (!d) {
          var model = monaco.editor.createModel(text, languageFor(path), monaco.Uri.file(path));
          d = docs[path] = { model: model, savedVersion: model.getAlternativeVersionId(), dirty: false, view: null };
        }
        current = path;
        editor.setModel(d.model);
        if (d.view) editor.restoreViewState(d.view);
        editor.focus();
      },
      close: function (path) {
        var d = docs[path]; if (!d) return;
        if (current === path) { editor.setModel(null); current = null; }
        d.model.dispose(); delete docs[path];
      },
      dirtyFiles: function () {
        var out = [];
        Object.keys(docs).forEach(function (p) {
          if (docs[p].dirty) out.push({ path: p, text: docs[p].model.getValue() });
        });
        return JSON.stringify(out);
      },
      markSaved: function (paths) {
        paths.forEach(function (p) {
          var d = docs[p]; if (!d) return;
          d.savedVersion = d.model.getAlternativeVersionId(); d.dirty = false;
        });
      },
      reload: function (path, text) {   // file changed on disk and the buffer is clean
        var d = docs[path]; if (!d) return;
        d.model.setValue(text);
        d.savedVersion = d.model.getAlternativeVersionId(); d.dirty = false;
      },
      reveal: function (path, line, column) {
        if (current !== path) return;
        var pos = { lineNumber: Math.max(1, line), column: Math.max(1, column || 1) };
        editor.setPosition(pos);
        editor.revealLineInCenter(pos.lineNumber);
        editor.focus();
      },
      setMarkers: function (path, items) {
        var d = docs[path]; if (!d) return;
        var markers = items.map(function (it) {
          var line = Math.min(Math.max(1, it.line), d.model.getLineCount());
          return {
            startLineNumber: line, startColumn: 1, endLineNumber: line, endColumn: d.model.getLineMaxColumn(line),
            message: it.message,
            severity: it.error ? monaco.MarkerSeverity.Error : monaco.MarkerSeverity.Warning
          };
        });
        monaco.editor.setModelMarkers(d.model, 'latex', markers);
      },
      clearMarkers: function () {
        Object.keys(docs).forEach(function (p) { monaco.editor.setModelMarkers(docs[p].model, 'latex', []); });
      },
      setTheme: function (dark) { monaco.editor.setTheme(dark ? 'easytex-dark' : 'easytex-light'); },
      setOptions: function (o) { editor.updateOptions(o); }
    };

    post({ type: 'ready' });
  });
})();
