// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library playground;

import 'dart:async';
import 'dart:html' hide Document;

import 'package:dart_pad/core/keys.dart';
import 'package:logging/logging.dart';
import 'package:route_hierarchical/client.dart';

import 'actions.dart';
import 'completion.dart';
import 'context.dart';
import 'core/dependencies.dart';
import 'core/modules.dart';
import 'dart_pad.dart';
import 'dartservices_client/v1.dart';
import 'doc_handler.dart';
import 'editing/editor.dart';
import 'elements/bind.dart';
import 'elements/elements.dart';
import 'modules/codemirror_module.dart';
import 'modules/dart_pad_module.dart';
import 'modules/dartservices_module.dart';
import 'parameter_popup.dart';
import 'services/common.dart';
import 'services/execution_iframe.dart';
import 'sharing/gists.dart';
import 'sharing/mutable_gist.dart';
import 'src/ga.dart';
import 'src/util.dart';

Playground get playground => _playground;

Playground _playground;

Logger _logger = new Logger('dartpad');

void init() {
  _playground = new Playground();
}

class Playground implements GistContainer {
  DivElement get _editpanel => querySelector('#editpanel');
  DivElement get _outputpanel => querySelector('#output');
  IFrameElement get _frame => querySelector('#frame');
  bool get _isCompletionActive => editor.completionActive;
  DivElement get _docPanel => querySelector('#documentation');
  AnchorElement get _docTab => querySelector('#doctab');
  bool get _isDocPanelOpen => _docTab.attributes.containsKey('selected');

  DButton runButton;
  DOverlay overlay;
  DBusyLight busyLight;
  Editor editor;
  PlaygroundContext _context;
  Future _analysisRequest;
  MutableGist editableGist = new MutableGist(new Gist());
  //GistStorage _gistStorage = new GistStorage();
  DContentEditable titleEditable;

  // We store the last returned shared gist; it's used to update the url.
  Gist _overrideNextRouteGist;
  Router _router;
  ParameterPopup paramPopup;
  DocHandler docHandler;

  ModuleManager modules = new ModuleManager();

  Playground() {
    _registerTab(querySelector('#darttab'), 'dart');
    _registerTab(querySelector('#htmltab'), 'html');
    _registerTab(querySelector('#csstab'), 'css');

    overlay = new DOverlay(querySelector('#frame_overlay'));

    new NewPadAction(querySelector('#newbutton'), editableGist/*, _gistStorage*/);

    new SharePadAction(querySelector('#sharebutton'), this);

    runButton = new DButton(querySelector('#runbutton'));
    runButton.onClick.listen((e) {
      _handleRun();

      // On a mobile device, focusing the editing area causes the keyboard to
      // pop up when the user hits the run button.
      if (!isMobile()) _context.focus();
    });

    busyLight = new DBusyLight(querySelector('#dartbusy'));

    // Update the title on changes.
    titleEditable = new DContentEditable(
        querySelector('header .header-gist-name'));
    bind(titleEditable.onChanged, editableGist.property('description'));
    bind(editableGist.property('description'), titleEditable.textProperty);

    // Update the ID on changes.
    AnchorElement idAnchor = querySelector('header .header-gist-id a');
    bind(editableGist.property('id'), (val) => idAnchor.text = val);
    bind(editableGist.property('html_url'), (val) {
      idAnchor.href = val == null ? '' : val;
    });

    // TODO(devoncarew): Commented out for now; more work is required on the
    // auto-persistence mechanism.
//    Throttler throttle = new Throttler(const Duration(milliseconds: 100));
//    mutableGist.onChanged.transform(throttle).listen((_) {
//      if (mutableGist.dirty) {
//        // If there was a change, and the gist is dirty, write the gist's
//        // contents to storage.
//        _gistStorage.setStoredGist(mutableGist.createGist());
//      }
//    });

    SelectElement select = querySelector('#samples');
    select.onChange.listen((_) => _handleSelectChanged(select));

    _initModules().then((_) {
      _initPlayground();
    });
  }

  void showHome(RouteEnterEvent event) {
    // TODO(devoncarew): Commented out for now; more work is required on the
    // auto-persistence mechanism.
//    if (_gistStorage.hasStoredGist && _gistStorage.storedId == null) {
//      editableGist.setBackingGist(_gistStorage.getStoredGist());
//    } else {
      editableGist.setBackingGist(createSampleGist());
//    }

    Timer.run(_handleRun);
  }

  void showGist(RouteEnterEvent event) {
    String gistId = event.parameters['gist'];

    if (!isLegalGistId(gistId)) {
      showHome(event);
      return;
    }

    _showGist(gistId);
  }

  // GistContainer interface
  MutableGist get mutableGist => editableGist;

  void overrideNextRoute(Gist gist) {
    _overrideNextRouteGist = gist;
  }

  void _showGist(String gistId) {
    // When sharing, we have to pipe the returned (created) gist through the
    // routing library to update the url properly.
    if (_overrideNextRouteGist != null && _overrideNextRouteGist.id == gistId) {
      editableGist.setBackingGist(_overrideNextRouteGist);
      _overrideNextRouteGist = null;
      return;
    }

    _overrideNextRouteGist = null;

    gistLoader.loadGist(gistId).then((Gist gist) {
      editableGist.setBackingGist(gist);

//      if (_gistStorage.hasStoredGist && _gistStorage.storedId == gistId) {
//        Gist storedGist = _gistStorage.getStoredGist();
//        mutableGist.description = storedGist.description;
//        for (GistFile file in storedGist.files) {
//          mutableGist.getGistFile(file.name).content = file.content;
//        }
//      }

      // Analyze and run it.
      Timer.run(() {
        _handleRun();
        _performAnalysis();
      });
    }).catchError((e) {
      String message = 'Error loading gist ${gistId}.';
      DToast.showMessage(message);
      _logger.severe('${message}: ${e}');
    });
  }

  Future _initModules() {
    modules.register(new DartPadModule());
    //modules.register(new MockDartServicesModule());
    modules.register(new DartServicesModule());
    //modules.register(new AceModule());
    modules.register(new CodeMirrorModule());

    return modules.start();
  }

  void _initPlayground() {
    // TODO: Set up some automatic value bindings.
    DSplitter editorSplitter = new DSplitter(querySelector('#editor_split'));
    editorSplitter.onPositionChanged.listen((pos) {
      state['editor_split'] = pos;
      editor.resize();
    });
    if (state['editor_split'] != null) {
     editorSplitter.position = state['editor_split'];
    }

    DSplitter outputSplitter = new DSplitter(querySelector('#output_split'));
    outputSplitter.onPositionChanged.listen((pos) {
      state['output_split'] = pos;
    });
    if (state['output_split'] != null) {
      outputSplitter.position = state['output_split'];
    }

    // Set up the iframe.
    deps[ExecutionService] = new ExecutionServiceIFrame(_frame);
    executionService.onStdout.listen(_showOuput);
    executionService.onStderr.listen((m) => _showOuput(m, error: true));

    // Set up Google Analytics.
    deps[Analytics] = new Analytics();

    // Set up the gist loader.
    deps[GistLoader] = new GistLoader.defaultFilters();

    // Set up the router.
    deps[Router] = new Router();
    router.root.addRoute(name: 'home', defaultRoute: true, enter: showHome);
    router.root.addRoute(name: 'gist', path: '/:gist', enter: showGist);
    router.listen();

    // Set up the editing area.
    editor = editorFactory.createFromElement(_editpanel);
    _editpanel.children.first.attributes['flex'] = '';
    editor.resize();

    keys.bind(['ctrl-s'], _handleSave);
    keys.bind(['ctrl-enter'], _handleRun);
    keys.bind(['f1'], () {
      ga.sendEvent('main', 'help');
      _toggleDocTab();
    });

    keys.bind(['alt-enter', 'ctrl-1'], (){
        editor.showCompletions(onlyShowFixes: true);
    });

    keys.bind(['ctrl-space', 'macctrl-space'], (){
      editor.showCompletions();
    });

    document.onClick.listen((MouseEvent e) {
      if (_isDocPanelOpen) docHandler.generateDoc(_docPanel);
    });

    document.onKeyUp.listen((e) {
      if (editor.completionActive || DocHandler.cursorKeys.contains(e.keyCode)){
        if (_isDocPanelOpen) docHandler.generateDoc(_docPanel);
      }
      _handleAutoCompletion(e);
    });

    _docTab.onClick.listen((e) => _toggleDocTab());
    querySelector("#consoletab").onClick.listen((e) => _toggleConsoleTab());

    _context = new PlaygroundContext(editor);
    deps[Context] = _context;

    editorFactory.registerCompleter(
        'dart', new DartCompleter(dartServices, _context._dartDoc));

    _context.onHtmlDirty.listen((_) => busyLight.on());
    _context.onHtmlReconcile.listen((_) {
      executionService.replaceHtml(_context.htmlSource);
      busyLight.reset();
    });

    _context.onCssDirty.listen((_) => busyLight.on());
    _context.onCssReconcile.listen((_) {
      executionService.replaceCss(_context.cssSource);
      busyLight.reset();
    });

    _context.onDartDirty.listen((_) => busyLight.on());
    _context.onDartReconcile.listen((_) => _performAnalysis());

    // Bind the editable files to the gist.
    Property htmlFile = new GistFileProperty(editableGist.getGistFile('index.html'));
    Property htmlDoc = new EditorDocumentProperty(_context.htmlDocument, 'html');
    bind(htmlDoc, htmlFile);
    bind(htmlFile, htmlDoc);

    Property cssFile = new GistFileProperty(editableGist.getGistFile('styles.css'));
    Property cssDoc = new EditorDocumentProperty(_context.cssDocument, 'css');
    bind(cssDoc, cssFile);
    bind(cssFile, cssDoc);

    Property dartFile = new GistFileProperty(editableGist.getGistFile('main.dart'));
    Property dartDoc = new EditorDocumentProperty(_context.dartDocument, 'dart');
    bind(dartDoc, dartFile);
    bind(dartFile, dartDoc);

    // Set up development options.
    options.registerOption('autopopup_code_completion', 'false');
    options.registerOption('parameter_popup', 'false');

    if (options.getValueBool("parameter_popup")) {
      paramPopup = new ParameterPopup(context, editor);
    }

    docHandler = new DocHandler(editor, _context);

    _finishedInit();
  }

  _finishedInit() {
    // Clear the splash.
    DSplash splash = new DSplash(querySelector('div.splash'));
    splash.hide();
  }

  void _registerTab(Element element, String name) {
    DElement component = new DElement(element);

    component.onClick.listen((_) {
      if (component.hasAttr('selected')) return;

      component.setAttr('selected');

      _getTabElements(component.element.parent.parent).forEach((c) {
        if (c != component.element && c.attributes.containsKey('selected')) {
          c.attributes.remove('selected');
        }
      });

      ga.sendEvent('edit', name);
      _context.switchTo(name);
    });
  }

  List<Element> _getTabElements(Element element) =>
      element.querySelectorAll('a');

  void _toggleDocTab() {
    ga.sendEvent('view', 'dartdoc');
    docHandler.generateDoc(_docPanel);
    // TODO:(devoncarew): We need a tab component (in lib/elements.dart).
    querySelector('#output').style.display = "none";
    querySelector("#consoletab").attributes.remove('selected');

    _docPanel.style.display = "block";
    _docTab.setAttribute('selected','');
  }

  void _toggleConsoleTab() {
    ga.sendEvent('view', 'console');
    _docPanel.style.display = "none";
    _docTab.attributes.remove('selected');

    _outputpanel.style.display = "block";
    querySelector("#consoletab").setAttribute('selected','');
  }

  _handleAutoCompletion(KeyboardEvent e) {
    // If we're already in completion bail or if the editor has no focus.
    // For example, if the title text is edited.
    if (_isCompletionActive || !editor.hasFocus) return;

    if (context.focusedEditor == 'dart') {
      if (e.keyCode == KeyCode.PERIOD) {
        editor.completionAutoInvoked = true;
        editor.execCommand("autocomplete");
      }
    }
    if (!options.getValueBool('autopopup_code_completion')) {
      return;
    }

    if (context.focusedEditor == 'dart') {
      RegExp exp = new RegExp(r"[A-Z]");
        if (exp.hasMatch(new String.fromCharCode(e.keyCode))) {
          editor.showCompletions(autoInvoked: true);
        }
    } else if (context.focusedEditor == "html") {
      if (options.getValueBool('autopopup_code_completion')) {
        // TODO: Autocompletion for attributes.
        if (printKeyEvent(e) == "shift-,") {
          editor.showCompletions(autoInvoked: true);
        }
      }
    } else if (context.focusedEditor == "css") {
      RegExp exp = new RegExp(r"[A-Z]");
      if (exp.hasMatch(new String.fromCharCode(e.keyCode))) {
        editor.showCompletions(autoInvoked: true);
      }
    }
  }

  void _handleRun() {
    _toggleConsoleTab();
    ga.sendEvent('main', 'run');
    runButton.disabled = true;
    overlay.visible = true;

    _clearOutput();

    Stopwatch compilationTimer = new Stopwatch()..start();

    var input = new SourceRequest()..source = context.dartSource;
    dartServices.compile(input).timeout(longServiceCallTimeout).then(
        (CompileResponse response) {
      ga.sendTiming('action-perf', "compilation-e2e",
          compilationTimer.elapsedMilliseconds);
      return executionService.execute(
          _context.htmlSource, _context.cssSource, response.result);
    }).catchError((e) {
      DToast.showMessage('Error compiling to JavaScript');
      ga.sendException("${e.runtimeType}");
      _showOuput('Error compiling to JavaScript:\n${e}', error: true);
    }).whenComplete(() {
      runButton.disabled = false;
      overlay.visible = false;
    });
  }

  void _performAnalysis() {
    var input = new SourceRequest()..source = _context.dartSource;
    Lines lines = new Lines(input.source);

    Future request = dartServices.analyze(input).timeout(serviceCallTimeout);
    _analysisRequest = request;

    request.then((AnalysisResults result) {
      // Discard if we requested another analysis.
      if (_analysisRequest != request) return;

      // Discard if the document has been mutated since we requested analysis.
      if (input.source != _context.dartSource) return;

      busyLight.reset();

      _displayIssues(result.issues);

      _context.dartDocument.setAnnotations(result.issues.map(
          (AnalysisIssue issue) {
        int startLine = lines.getLineForOffset(issue.charStart);
        int endLine = lines.getLineForOffset(issue.charStart + issue.charLength);

        Position start = new Position(startLine,
            issue.charStart - lines.offsetForLine(startLine));
        Position end = new Position(endLine,
            issue.charStart + issue.charLength - lines.offsetForLine(startLine));

        return new Annotation(issue.kind, issue.message, issue.line,
            start: start, end: end);
      }).toList());

      _updateRunButton(
          hasErrors: result.issues.any((issue) => issue.kind == 'error'),
          hasWarnings: result.issues.any((issue) => issue.kind == 'warning'));
    }).catchError((e) {
      _context.dartDocument.setAnnotations([]);
      busyLight.reset();
      _updateRunButton();
      _logger.severe(e);
    });
  }

  void _handleSave() {
    ga.sendEvent('main', 'save');
  }

  void _clearOutput() {
    _outputpanel.text = '';
  }

  void _showOuput(String message, {bool error: false}) {
    message = message + '\n';
    SpanElement span = new SpanElement();
    span.classes.add(error ? 'errorOutput' : 'normal');
    span.text = message;
    _outputpanel.children.add(span);
    span.scrollIntoView(ScrollAlignment.BOTTOM);
  }

  void _handleSelectChanged(SelectElement select) {
    String value = select.value;

    if (isLegalGistId(value)) {
      router.go('gist', {'gist': value});
    }

    select.value = '0';
  }

  void _setGistDescription(String description) {
    titleEditable.text = description == null ? '' : description;
  }

  void _displayIssues(List<AnalysisIssue> issues) {
    Element issuesElement = querySelector('#issues');

    // Detect when hiding; don't remove the content until hidden.
    bool isHiding = issuesElement.children.isNotEmpty && issues.isEmpty;

    if (isHiding) {
      issuesElement.classes.toggle('showing', issues.isNotEmpty);

      StreamSubscription sub;
      sub = issuesElement.onTransitionEnd.listen((_) {
        issuesElement.children.clear();
        sub.cancel();
      });
    } else {
      issuesElement.children.clear();

      issues.sort((a, b) => a.charStart - b.charStart);

      // Create an item for each issue.
      for (AnalysisIssue issue in issues) {
        DivElement e = new DivElement();
        e.classes.add('issue');
        issuesElement.children.add(e);
        e.onClick.listen((_) {
          _jumpTo(issue.line, issue.charStart, issue.charLength, focus: true);
        });

        SpanElement typeSpan = new SpanElement();
        typeSpan.classes.addAll([issue.kind, 'issuelabel']);
        typeSpan.text = issue.kind;
        e.children.add(typeSpan);

        SpanElement messageSpan = new SpanElement();
        messageSpan.classes.add('message');
        messageSpan.text = issue.message;
        e.children.add(messageSpan);
        if (issue.hasFixes) {
          e.classes.add("hasFix");
          e.onClick.listen((e) {
            // This is a bit of a hack to make sure quick fixes popup
            // is only shown if the wrench is clicked,
            // and not if the text or label is clicked.
            if ((e.target as Element).className == "issue hasFix") {
              // codemiror only shows completions if there is no selected text
              _jumpTo(issue.line, issue.charStart, 0, focus: true);
              editor.showCompletions(onlyShowFixes: true);
            }
          });
        }
      }

      issuesElement.classes.toggle('showing', issues.isNotEmpty);
    }
  }

  void _updateRunButton({bool hasErrors: false, bool hasWarnings: false}) {
    const alertSVGIcon =
        "M5,3H19A2,2 0 0,1 21,5V19A2,2 0 0,1 19,21H5A2,2 0 0,1 3,19V5A2,2 0 0,"
        "1 5,3M13,13V7H11V13H13M13,17V15H11V17H13Z";

    var path = runButton.element.querySelector("path");
    path.attributes["d"] =
        (hasErrors || hasWarnings) ? alertSVGIcon : "M8 5v14l11-7z";

    path.parent.classes.toggle("error", hasErrors);
    path.parent.classes.toggle("warning", hasWarnings && !hasErrors);
  }

  void _jumpTo(int line, int charStart, int charLength, {bool focus: false}) {
    Document doc = editor.document;

    doc.select(
        doc.posFromIndex(charStart),
        doc.posFromIndex(charStart + charLength));

    if (focus) editor.focus();
  }
}

class PlaygroundContext extends Context {
  final Editor editor;

  Document _dartDoc;
  Document _htmlDoc;
  Document _cssDoc;

  StreamController _cssDirtyController = new StreamController.broadcast();
  StreamController _dartDirtyController = new StreamController.broadcast();
  StreamController _htmlDirtyController = new StreamController.broadcast();

  StreamController _cssReconcileController = new StreamController.broadcast();
  StreamController _dartReconcileController = new StreamController.broadcast();
  StreamController _htmlReconcileController = new StreamController.broadcast();

  PlaygroundContext(this.editor) {
    editor.mode = 'dart';
    _dartDoc = editor.document;
    _htmlDoc = editor.createDocument(content: '', mode: 'html');
    _cssDoc = editor.createDocument(content: '', mode: 'css');

    _dartDoc.onChange.listen((_) => _dartDirtyController.add(null));
    _htmlDoc.onChange.listen((_) => _htmlDirtyController.add(null));
    _cssDoc.onChange.listen((_) => _cssDirtyController.add(null));

    _createReconciler(_cssDoc, _cssReconcileController, 250);
    _createReconciler(_dartDoc, _dartReconcileController, 1250);
    _createReconciler(_htmlDoc, _htmlReconcileController, 250);
  }

  Document get dartDocument => _dartDoc;
  Document get htmlDocument => _htmlDoc;
  Document get cssDocument => _cssDoc;

  String get dartSource => _dartDoc.value;
  set dartSource(String value) {
    _dartDoc.value = value;
  }

  String get htmlSource => _htmlDoc.value;
  set htmlSource(String value) {
    _htmlDoc.value = value;
  }

  String get cssSource => _cssDoc.value;
  set cssSource(String value) {
    _cssDoc.value = value;
  }

  String get activeMode => editor.mode;

  void switchTo(String name) {
    if (name == 'dart') {
      editor.swapDocument(_dartDoc);
    } else if (name == 'html') {
      editor.swapDocument(_htmlDoc);
    } else if (name == 'css') {
      editor.swapDocument(_cssDoc);
    }

    editor.focus();
  }

  String get focusedEditor {
    if (editor.document == _htmlDoc) return 'html';
    if (editor.document == _cssDoc) return 'css';
    return 'dart';
  }

  Stream get onCssDirty => _cssDirtyController.stream;
  Stream get onDartDirty => _dartDirtyController.stream;
  Stream get onHtmlDirty => _htmlDirtyController.stream;

  Stream get onCssReconcile => _cssReconcileController.stream;
  Stream get onDartReconcile => _dartReconcileController.stream;
  Stream get onHtmlReconcile => _htmlReconcileController.stream;

  void markCssClean() => _cssDoc.markClean();
  void markDartClean() => _dartDoc.markClean();
  void markHtmlClean() => _htmlDoc.markClean();

  /**
   * Restore the focus to the last focused editor.
   */
  void focus() => editor.focus();

  void _createReconciler(Document doc, StreamController controller, int delay) {
    Timer timer;
    doc.onChange.listen((_) {
      if (timer != null) timer.cancel();
      timer = new Timer(new Duration(milliseconds: delay), () {
        controller.add(null);
      });
    });
  }
}

class GistFileProperty implements Property {
  final MutableGistFile file;

  GistFileProperty(this.file);

  get() => file.content;

  void set(value) {
    if (file.content != value) {
      file.content = value;
    }
  }

  Stream get onChanged => file.onChanged.map((value) {
    return value;
  });
}

class EditorDocumentProperty implements Property {
  final Document document;
  final String debugName;

  EditorDocumentProperty(this.document, [this.debugName]);

  get() => document.value;

  void set(str) {
    document.value = str == null ? '' : str;
  }

  Stream get onChanged => document.onChange.map((_) => get());
}
