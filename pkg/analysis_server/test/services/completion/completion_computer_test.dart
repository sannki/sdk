// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library test.services.completion.suggestion;

import 'dart:async';

import 'package:analysis_server/plugin/protocol/protocol.dart';
import 'package:analysis_server/src/analysis_server.dart';
import 'package:analysis_server/src/provisional/completion/completion_core.dart'
    show CompletionRequest, CompletionResult;
import 'package:analysis_server/src/services/completion/completion_manager.dart';
import 'package:analysis_server/src/services/completion/dart_completion_manager.dart';
import 'package:analysis_server/src/services/index/index.dart';
import 'package:analysis_server/src/services/index/local_memory_index.dart';
import 'package:analysis_server/src/services/search/search_engine.dart';
import 'package:analysis_server/src/services/search/search_engine_internal.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';
import 'package:unittest/unittest.dart';

import '../../abstract_single_unit.dart';
import '../../operation/operation_queue_test.dart';
import '../../utils.dart';

main() {
  initializeTestEnvironment();
  defineReflectiveTests(DartCompletionManagerTest);
}

/**
 * Returns a [Future] that completes after pumping the event queue [times]
 * times. By default, this should pump the event queue enough times to allow
 * any code to run, as long as it's not waiting on some external event.
 */
Future pumpEventQueue([int times = 20]) {
  if (times == 0) return new Future.value();
  // We use a delayed future to allow microtask events to finish. The
  // Future.value or Future() constructors use scheduleMicrotask themselves and
  // would therefore not wait for microtask callbacks that are scheduled after
  // invoking this method.
  return new Future.delayed(Duration.ZERO, () => pumpEventQueue(times - 1));
}

@reflectiveTest
class DartCompletionManagerTest extends AbstractSingleUnitTest {
  Index index;
  SearchEngineImpl searchEngine;
  Source source;
  DartCompletionManager manager;
  MockCompletionContributor contributor1;
  MockCompletionContributor contributor2;
  CompletionSuggestion suggestion1;
  CompletionSuggestion suggestion2;
  bool _continuePerformingAnalysis = true;

  void resolveLibrary() {
    context.resolveCompilationUnit(
        source, context.computeLibraryElement(source));
  }

  @override
  void setUp() {
    super.setUp();
    index = createLocalMemoryIndex();
    searchEngine = new SearchEngineImpl(index);
    source = addSource('/does/not/exist.dart', '');
    manager = new DartCompletionManager.create(context, searchEngine, source);
    suggestion1 = new CompletionSuggestion(CompletionSuggestionKind.INVOCATION,
        DART_RELEVANCE_DEFAULT, "suggestion1", 1, 1, false, false);
    suggestion2 = new CompletionSuggestion(CompletionSuggestionKind.IDENTIFIER,
        DART_RELEVANCE_DEFAULT, "suggestion2", 2, 2, false, false);
    new Future(_performAnalysis);
  }

  @override
  void tearDown() {
    _continuePerformingAnalysis = false;
  }

  test_compute_fastAndFull() {
    contributor1 = new MockCompletionContributor(suggestion1, null);
    contributor2 = new MockCompletionContributor(null, suggestion2);
    manager.contributors = [contributor1, contributor2];
    manager.newContributors = [];
    int count = 0;
    bool done = false;
    AnalysisServer server = new AnalysisServerMock(searchEngine: searchEngine);
    CompletionRequest completionRequest =
        new CompletionRequestImpl(server, context, source, 0);
    manager.results(completionRequest).listen((CompletionResult r) {
      bool isLast = r is CompletionResultImpl ? r.isLast : true;
      switch (++count) {
        case 1:
          contributor1.assertCalls(context, source, 0, searchEngine);
          expect(contributor1.fastCount, equals(1));
          expect(contributor1.fullCount, equals(0));
          contributor2.assertCalls(context, source, 0, searchEngine);
          expect(contributor2.fastCount, equals(1));
          expect(contributor2.fullCount, equals(1));
          expect(isLast, isTrue);
          expect(r.suggestions, hasLength(2));
          expect(r.suggestions, contains(suggestion1));
          expect(r.suggestions, contains(suggestion2));
          resolveLibrary();
          break;
        default:
          fail('unexpected');
      }
    }, onDone: () {
      done = true;
      // There is only one notification
      expect(count, equals(1));
    });
    return pumpEventQueue(250).then((_) {
      expect(done, isTrue);
    });
  }

  test_compute_fastOnly() {
    contributor1 = new MockCompletionContributor(suggestion1, null);
    contributor2 = new MockCompletionContributor(suggestion2, null);
    manager.contributors = [contributor1, contributor2];
    manager.newContributors = [];
    int count = 0;
    bool done = false;
    AnalysisServer server = new AnalysisServerMock(searchEngine: searchEngine);
    CompletionRequest completionRequest =
        new CompletionRequestImpl(server, context, source, 0);
    manager.results(completionRequest).listen((CompletionResult r) {
      bool isLast = r is CompletionResultImpl ? r.isLast : true;
      switch (++count) {
        case 1:
          contributor1.assertCalls(context, source, 0, searchEngine);
          expect(contributor1.fastCount, equals(1));
          expect(contributor1.fullCount, equals(0));
          contributor2.assertCalls(context, source, 0, searchEngine);
          expect(contributor2.fastCount, equals(1));
          expect(contributor2.fullCount, equals(0));
          expect(isLast, isTrue);
          expect(r.suggestions, hasLength(2));
          expect(r.suggestions, contains(suggestion1));
          expect(r.suggestions, contains(suggestion2));
          break;
        default:
          fail('unexpected');
      }
    }, onDone: () {
      done = true;
      expect(count, equals(1));
    });
    return pumpEventQueue().then((_) {
      expect(done, isTrue);
    });
  }

  void _performAnalysis() {
    if (!_continuePerformingAnalysis) {
      return;
    }
    context.performAnalysisTask();
    new Future(_performAnalysis);
  }
}

class MockCompletionContributor extends DartCompletionContributor {
  final CompletionSuggestion fastSuggestion;
  final CompletionSuggestion fullSuggestion;
  int fastCount = 0;
  int fullCount = 0;
  DartCompletionRequest request;

  MockCompletionContributor(this.fastSuggestion, this.fullSuggestion);

  assertCalls(AnalysisContext context, Source source, int offset,
      SearchEngine searchEngine) {
    expect(request.context, equals(context));
    expect(request.source, equals(source));
    expect(request.offset, equals(offset));
    expect(request.searchEngine, equals(searchEngine));
  }

  assertFull(int fullCount) {
    expect(this.fastCount, equals(1));
    expect(this.fullCount, equals(fullCount));
  }

  @override
  bool computeFast(DartCompletionRequest request) {
    this.request = request;
    fastCount++;
    if (fastSuggestion != null) {
      request.addSuggestion(fastSuggestion);
    }
    return fastSuggestion != null;
  }

  @override
  Future<bool> computeFull(DartCompletionRequest request) {
    this.request = request;
    fullCount++;
    if (fullSuggestion != null) {
      request.addSuggestion(fullSuggestion);
    }
    return new Future.value(fullSuggestion != null);
  }
}
