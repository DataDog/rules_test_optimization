# Test Optimization Bazel support

## Approach Overview

The proposed plan integrates Datadog Test Optimization with Bazel using a repository module extension.

The steps are:

1. **Repository extension**:   
   The extension gathers information from the backend, then writes JSON files into Bazel’s test runner sandbox.  
   POC: [https://github.com/DataDog/rules\_test\_optimization](https://github.com/DataDog/rules_test_optimization) 

2. **Test instrumentation**:  
   Tests are instrumented by the tracer library, just like in standard Test Optimization. When running under Bazel, the library detects the environment, reads the JSON files, and writes test result payloads to the file system.

3. **Payload reporting**:  
   A dedicated module consumes these payloads and sends them back to the backend. To be defined…

## Why a repository extension?

- **Hermeticity**: Bazel sandboxes can be hermetic (isolated, with no network access). The extension lets us gather backend data ahead of time.  
    
- **Environment access**: It gives us visibility into repository-level environment variables.  
    
- **Backend data gathering**: We can run curl commands once to fetch backend data and persist it into JSON files within a filegroup.  
    
- **Cache friendliness**: By making this filegroup a dependency of the test rules, Bazel’s caching only invalidates when these JSON files change.

## Cache Invalidation Scenarios

### Settings updates

Any configuration change in the Datadog UI (feature toggles, test settings, etc.) regenerates the settings JSON file. This naturally invalidates the test rule cache. Since the tracer library depends on these settings, this is unavoidable.

### Early Flake Detection & “New” Test Tagging

These features rely on an API that returns the list of known tests for a service.

* Adding a new test already invalidates the cache for its test rule.  
* However, our current granularity is service-wide, meaning a single new test invalidates all test rules for the service.  
* To mitigate, we could make this feature opt-in at the extension level (not only in the UI) so teams control cache invalidation more explicitly at the repository level.

### Test Impact Analysis (TIA)

Datadog’s TIA works at the file level, similar to Bazel’s caching model. Bazel won’t re-run tests if source files are unchanged.

* Ideally, TIA could bring finer granularity within large test rules, but its mechanism requires a “skippable tests” JSON file.  
* This file itself invalidates the cache exactly when Bazel would skip the test rule, creating interference.  
* Given the overlap and uncertainty, the value of supporting TIA in Bazel is questionable. Making it opt-in is possible, but we must weigh whether it’s worth supporting at all.

### Flaky Test Management

This feature depends on a JSON list of flaky tests and their statuses (e.g. disabled, quarantined).

* Any status update invalidates the cache for the affected test rules.  
* Granularity is still service-level, but unlike TIA, this feature clearly provides customer value even with cache invalidations.

## Summary

The repository extension approach enables Bazel support for Test Optimization in a hermetic, cache-friendly way. Some features, however, interact with caching in awkward ways. Settings updates and flaky management remain valuable despite cache hits. Early flake detection and TIA require careful consideration, and might best be gated behind opt-in flags to avoid disrupting the Bazel workflow unnecessarily.