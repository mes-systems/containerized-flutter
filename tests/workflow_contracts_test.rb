#!/usr/bin/env ruby

require "fileutils"
require "json"
require "open3"
require "socket"
require "tmpdir"
require "test/unit"
require "yaml"

ROOT = File.expand_path("..", __dir__)
SLSA_TYPE = "https://slsa.dev/provenance/v1"
SPDX_TYPE = "https://spdx.dev/Document"
BUILD_TYPE = "https://github.com/moby/buildkit/blob/master/docs/attestations/slsa-definitions.md"
BUILD_DIGEST = "a" * 64
BASE_DIGEST = "b" * 64
COMMIT_OID = "c" * 40

class WorkflowContractsTest < Test::Unit::TestCase
  def setup
    @temporary_directory = Dir.mktmpdir("workflow-contracts-")
    @bin_directory = File.join(@temporary_directory, "bin")
    FileUtils.mkdir_p(@bin_directory)
    @watcher_counter = 0
    bash_version, = Open3.capture2("bash", "--version")
    version = bash_version.match(/version (\d+)/)
    @supports_bash_case_conversion = version && version[1].to_i >= 4
    install_curl_stub
    install_docker_stub
    install_gh_stub
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory) if File.directory?(@temporary_directory)
  end

  def workflow(name)
    @workflows ||= {}
    @workflows[name] ||= YAML.load_file(File.join(ROOT, ".github", "workflows", "#{name}.yml"), aliases: false)
  end

  def workflow_events(document)
    document["on"] || document[true] || {}
  end

  def job_steps(document, job_name)
    document.fetch("jobs").fetch(job_name).fetch("steps")
  end

  def step_named(document, job_name, name)
    job_steps(document, job_name).find { |step| step["name"] == name } ||
      raise("workflow step not found: #{name}")
  end

  def run_step(step, cwd: ROOT, env: {}, expressions: {})
    script = step.fetch("run")
    script = script.gsub(/\$\{\{\s*([^}]+?)\s*\}\}/) do |expression|
      expressions.fetch(Regexp.last_match(1).strip) do
        raise("no fixture value supplied for workflow expression #{expression}")
      end
    end
    assert_not_match(/\$\{\{/, script, "workflow expression was not resolved in test fixture")
    stdout, stderr, status = Open3.capture3(
      {"PATH" => "#{@bin_directory}:#{ENV.fetch('PATH', '')}"}.merge(env.transform_values(&:to_s)),
      "bash", "-e", "-o", "pipefail", "-c", script, chdir: cwd,
    )
    [status, stderr, stdout]
  end

  def output_values(path)
    File.readlines(path, chomp: true).to_h do |line|
      key, value = line.split("=", 2)
      [key, value]
    end
  end

  def step_position(steps, &predicate)
    steps.index(&predicate) || raise("workflow step not found for contract")
  end

  def markdown_link_targets(markdown)
    markdown.scan(/\[[^\]]+\]\(([^)]+)\)/).flatten
  end

  def test_all_actions_are_pinned_to_full_commit_identifiers
    Dir[File.join(ROOT, ".github", "workflows", "*.yml")].each do |path|
      YAML.load_file(path, aliases: false).fetch("jobs").each do |job_name, job|
        Array(job["steps"]).each do |step|
          next unless step["uses"]
          action, revision = step.fetch("uses").split("@", 2)
          assert_match(/\A[0-9a-f]{40}\z/, revision.to_s, "#{File.basename(path)} #{job_name}: #{action}")
        end
      end
    end
  end

  def test_ci_and_publish_jobs_declare_local_build_and_release_contracts
    ci = workflow("ci")
    publish = workflow("publish")
    assert_include(workflow_events(ci).keys, "pull_request")
    assert_include(workflow_events(ci).keys, "workflow_dispatch")
    assert_equal({"contents" => "read"}, ci.fetch("permissions"))
    manifest = ci.fetch("jobs").fetch("manifest")
    %w[ci_mode matrix build_needed].each { |key| assert_include(manifest.fetch("outputs").keys, key) }
    assert_equal("manifest", ci.fetch("jobs").fetch("build").fetch("needs"))
    gate = ci.fetch("jobs").fetch("ci-gate")
    assert_equal("always()", gate.fetch("if"))
    assert_equal(["manifest", "build"], gate.fetch("needs"))

    assert_equal(["main"], workflow_events(publish).fetch("push").fetch("branches"))
    assert_include(workflow_events(publish).keys, "workflow_dispatch")
    publish_job = publish.fetch("jobs").fetch("publish")
    assert_equal("manifest", publish_job.fetch("needs"))
    assert_match(/refs\/heads\/main/, publish_job.fetch("if"))
    assert_equal(
      {"contents" => "read", "packages" => "write", "id-token" => "write", "attestations" => "write"},
      publish_job.fetch("permissions"),
    )

    [[ci, "build"], [publish, "publish"]].each do |document, job_name|
      steps = job_steps(document, job_name)
      steps.each do |step|
        next unless step["uses"].to_s.start_with?("actions/checkout@")
        assert_equal(false, step.fetch("with").fetch("persist-credentials"))
      end
      build_index = step_position(steps) { |step| step["uses"].to_s.start_with?("docker/build-push-action@") }
      build = steps.fetch(build_index)
      assert_equal("linux/amd64", build.fetch("with").fetch("platforms"))
      assert_equal(true, build.fetch("with").fetch("load"))
      assert_equal(false, build.fetch("with").fetch("push"))
      assert_equal("mode=max,version=v1", build.fetch("with").fetch("provenance"))
      assert_equal(true, build.fetch("with").fetch("sbom"))
      build_args = build.fetch("with").fetch("build-args").lines.map { |line| line.strip.split("=", 2) }
      assert_equal(
        %w[BASE_IMAGE FLUTTER_VERSION FLUTTER_CHANNEL FLUTTER_REVISION FLUTTER_ARCHIVE_SHA256 SOURCE_REVISION].sort,
        build_args.map(&:first).sort,
      )
      assert_match(/matrix\.base_reference/, build_args.assoc("BASE_IMAGE").last)
      assert_not_match(/secrets\./, build_args.map(&:last).join("\n"))
      docker_setup = steps.find { |step| step["uses"].to_s.start_with?("docker/setup-docker-action@") }
      assert_not_nil(docker_setup)
      assert_equal("v29.8.0", docker_setup.fetch("with").fetch("version"))
      assert_equal(true, JSON.parse(docker_setup.fetch("with").fetch("daemon-config")).dig("features", "containerd-snapshotter"))

      verifier_index = step_position(steps) { |step| step["env"].is_a?(Hash) && step["env"].key?("DOCKER_SOCKET") }
      smoke_index = step_position(steps) { |step| step["name"] == "Smoke test image" }
      assert_operator(build_index, :<, verifier_index)
      assert_operator(verifier_index, :<, smoke_index)
      assert_equal("always()", step_named(document, job_name, "Remove tested image").fetch("if"))
    end

    publish_steps = job_steps(publish, "publish")
    smoke_index = step_position(publish_steps) { |step| step["name"] == "Smoke test image" }
    login_index = step_position(publish_steps) { |step| step["uses"].to_s.start_with?("docker/login-action@") }
    push_index = step_position(publish_steps) { |step| step["id"] == "push" }
    attest_index = step_position(publish_steps) { |step| step["uses"].to_s.start_with?("actions/attest@") }
    assert_operator(smoke_index, :<, login_index)
    assert_operator(login_index, :<, push_index)
    assert_operator(push_index, :<, attest_index)
    assert_equal(false, publish_steps.fetch(attest_index).fetch("with").fetch("push-to-registry"))
    assert_equal(false, publish_steps.fetch(attest_index).fetch("with").fetch("create-storage-record"))

    [ci, publish].each do |document|
      runner = document.fetch("jobs").values.flat_map { |job| Array(job["steps"]) }
        .find { |step| step["run"].to_s.strip == "tests/scripts_test.sh" }
      assert_not_nil(runner, "workflow must execute the repository script harness")
    end
  end

  def test_watcher_and_scorecard_schedules_permissions_and_forms_are_structural
    {"flutter-release-watch" => "30 3 * * *", "base-image-watch" => "0 3 * * *"}.each do |name, cron|
      document = workflow(name)
      events = workflow_events(document)
      assert_equal(cron, events.fetch("schedule").first.fetch("cron"))
      assert_include(events.keys, "workflow_dispatch")
      assert_equal({"contents" => "read"}, document.fetch("permissions"))
      watcher = document.fetch("jobs").fetch("watch")
      assert_equal({"name" => "flutter-release-watcher", "deployment" => false}, watcher.fetch("environment"))
      checkout = job_steps(document, "watch").find { |step| step["uses"].to_s.start_with?("actions/checkout@") }
      assert_equal("main", checkout.fetch("with").fetch("ref"))
      assert_equal(false, checkout.fetch("with").fetch("persist-credentials"))
      token = job_steps(document, "watch").find { |step| step["id"] == "app-token" }
      assert_not_nil(token)
      %w[contents pull-requests issues].each { |scope| assert_equal("write", token.fetch("with").fetch("permission-#{scope}")) }
      assert_equal("read", token.fetch("with").fetch("permission-metadata"))
      assert_include(job_steps(document, "watch").map { |step| step["run"].to_s }.join("\n"), "tests/scripts_test.sh")
    end

    scorecard = workflow("scorecard")
    events = workflow_events(scorecard)
    assert_equal(["main"], events.fetch("push").fetch("branches"))
    assert_include(events.keys, "schedule")
    assert_not_include(events.keys, "pull_request")
    assert_equal({"contents" => "read"}, scorecard.fetch("permissions"))
    assert_equal(
      {"contents" => "read", "security-events" => "write", "id-token" => "write"},
      scorecard.fetch("jobs").fetch("analysis").fetch("permissions"),
    )
    scorecard_steps = job_steps(scorecard, "analysis")
    analysis = scorecard_steps.find { |step| step["uses"].to_s.start_with?("ossf/scorecard-action@") }
    assert_equal("sarif", analysis.fetch("with").fetch("results_format"))
    assert_equal(true, analysis.fetch("with").fetch("publish_results"))
    upload = scorecard_steps.find { |step| step["uses"].to_s.start_with?("actions/upload-artifact@") }
    assert_equal(5, upload.fetch("with").fetch("retention-days"))
    assert(scorecard_steps.any? { |step| step["uses"].to_s.start_with?("github/codeql-action/upload-sarif@") })

    dependabot = YAML.load_file(File.join(ROOT, ".github", "dependabot.yml"), aliases: false)
    ecosystems = dependabot.fetch("updates").map { |update| update.fetch("package-ecosystem") }
    assert_include(ecosystems, "github-actions")
    assert_not_include(ecosystems, "docker")
    form = YAML.load_file(File.join(ROOT, ".github", "VULNERABILITY_REPORT.yml"), aliases: false)
    fields = form.fetch("body").reject { |item| item["type"] == "markdown" }
    ids = fields.map { |field| field.fetch("id") }
    assert_equal(ids.uniq, ids)
    %w[summary affected_component affected_image flutter_version base_image details proof_of_concept impact upstream_relationship additional_context].each do |id|
      assert_include(ids, id)
    end
    poc = fields.find { |field| field["id"] == "proof_of_concept" }
    assert_equal(true, poc.fetch("validations").fetch("required"))
    assert_equal(150, poc.fetch("validations").fetch("min_length"))

    security_policy = File.read(File.join(ROOT, "SECURITY.md"))
    security_links = markdown_link_targets(security_policy)
    [
      "https://g.co/vulnz",
      "https://github.com/flutter/.github/blob/main/SECURITY.md",
      "https://ubuntu.com/security/disclosure-policy",
      "https://www.debian.org/security/faq",
    ].each { |target| assert_include(security_links, target) }
    form_intro = form.fetch("body").find { |item| item["type"] == "markdown" }.fetch("attributes").fetch("value")
    form_links = markdown_link_targets(form_intro)
    assert_include(
      form_links,
      "https://github.com/mes-systems/containerized-flutter/blob/main/SECURITY.md",
    )
    assert_not_include(form_links, "https://github.com/mes-systems/containerized-flutter/issues/new")
  end

  def test_ci_classification_and_matrix_steps_emit_behavioral_outputs
    ci = workflow("ci")
    classify = job_steps(ci, "manifest").find { |step| step["id"] == "classify" }
    matrix = job_steps(ci, "manifest").find { |step| step["id"] == "matrix" }
    docs = make_classification_repository("README.md")
    event = {"pull_request" => {"base" => {"sha" => docs.fetch(:base_sha)}, "head" => {"sha" => docs.fetch(:head_sha)}}}
    dispatch = run_ci_classification(classify, "workflow_dispatch", {})
    assert_equal(0, dispatch.fetch(:result).exitstatus)
    assert_equal("full", output_values(dispatch.fetch(:output)).fetch("ci_mode"))
    malformed = run_ci_classification(classify, "pull_request", {"pull_request" => {"base" => {}, "head" => {}}})
    assert_equal(0, malformed.fetch(:result).exitstatus)
    assert_equal("full", output_values(malformed.fetch(:output)).fetch("ci_mode"))
    fetch_failure = run_ci_classification(classify, "pull_request", event, fetch_status: 1, cwd: docs.fetch(:directory))
    assert_equal(0, fetch_failure.fetch(:result).exitstatus)
    assert_equal("full", output_values(fetch_failure.fetch(:output)).fetch("ci_mode"))
    unchanged = run_ci_classification(classify, "pull_request", event, fetch_status: 0, cwd: docs.fetch(:directory))
    assert_equal(0, unchanged.fetch(:result).exitstatus, unchanged.fetch(:stderr))
    values = output_values(unchanged.fetch(:output))
    assert_equal("none", values.fetch("ci_mode"))
    assert_equal(docs.fetch(:base_sha), values.fetch("base_sha"))

    selective = make_classification_repository("supported_version.json")
    selective_event = {"pull_request" => {"base" => {"sha" => selective.fetch(:base_sha)}, "head" => {"sha" => selective.fetch(:head_sha)}}}
    classified_selective = run_ci_classification(
      classify, "pull_request", selective_event, fetch_status: 0, cwd: selective.fetch(:directory),
    )
    assert_equal("selective", output_values(classified_selective.fetch(:output)).fetch("ci_mode"))

    full = make_classification_repository("Dockerfile")
    full_event = {"pull_request" => {"base" => {"sha" => full.fetch(:base_sha)}, "head" => {"sha" => full.fetch(:head_sha)}}}
    classified_full = run_ci_classification(classify, "pull_request", full_event, fetch_status: 0, cwd: full.fetch(:directory))
    assert_equal("full", output_values(classified_full.fetch(:output)).fetch("ci_mode"))

    ["none", "full"].each do |mode|
      output = File.join(@temporary_directory, "matrix-#{mode}.txt")
      result, stderr, = run_step(
        matrix,
        env: {"GITHUB_OUTPUT" => output, "RUNNER_TEMP" => @temporary_directory},
        expressions: {
          "steps.classify.outputs.ci_mode" => mode,
          "steps.classify.outputs.base_sha" => docs.fetch(:base_sha),
        },
      )
      assert_equal(0, result.exitstatus, stderr)
      values = output_values(output)
      assert_equal(mode, values.fetch("ci_mode"))
      assert_equal(mode == "full" ? "true" : "false", values.fetch("build_needed"))
      emitted_matrix = JSON.parse(values.fetch("matrix"))
      if mode == "none"
        assert_equal([], emitted_matrix.fetch("include"))
      else
        versions = JSON.parse(File.read(File.join(ROOT, "supported_version.json"))).fetch("supported_versions")
        bases = JSON.parse(File.read(File.join(ROOT, "supported_bases.json"))).fetch("bases")
        expected_pairs = versions.flat_map { |version| bases.map { |base| [version.fetch("version"), base.fetch("id")] } }
        actual_pairs = emitted_matrix.fetch("include").map { |row| [row.fetch("version"), row.fetch("base_id")] }
        assert_equal(expected_pairs, actual_pairs)
      end
    end
  end

  def test_publish_planner_handles_dispatch_and_rejects_unavailable_revisions
    plan = job_steps(workflow("publish"), "manifest").find { |step| step["id"] == "plan" }
    output = File.join(@temporary_directory, "publish-dispatch.txt")
    result, stderr, = run_step(plan, env: {"GITHUB_EVENT_NAME" => "workflow_dispatch", "GITHUB_OUTPUT" => output})
    assert_equal(0, result.exitstatus, stderr)
    values = output_values(output)
    assert_equal("full", values.fetch("publish_mode"))
    assert_equal("true", values.fetch("publish_needed"))
    expected_count =
      JSON.parse(File.read(File.join(ROOT, "supported_version.json"))).fetch("supported_versions").length *
      JSON.parse(File.read(File.join(ROOT, "supported_bases.json"))).fetch("bases").length
    assert_equal(expected_count, JSON.parse(values.fetch("publish_matrix")).fetch("include").length)

    event_path = File.join(@temporary_directory, "push-event.json")
    output = File.join(@temporary_directory, "publish-invalid.txt")
    File.write(output, "")
    File.write(event_path, JSON.generate({"before" => "", "after" => ""}))
    result, = run_step(
      plan, env: {"GITHUB_EVENT_NAME" => "push", "GITHUB_EVENT_PATH" => event_path, "GITHUB_OUTPUT" => output},
    )
    assert_not_equal(0, result.exitstatus)
    assert_equal("", File.read(output))

    main_sha, = Open3.capture2("git", "rev-parse", "refs/remotes/origin/main", chdir: ROOT)
    File.write(event_path, JSON.generate({"before" => main_sha.strip, "after" => main_sha.strip}))
    result, stderr, = run_step(
      plan,
      env: git_fetch_environment(1).merge(
        "GITHUB_EVENT_NAME" => "push", "GITHUB_EVENT_PATH" => event_path, "GITHUB_OUTPUT" => output,
      ),
    )
    assert_not_equal(0, result.exitstatus)
    assert_include(stderr, "could not fetch push revisions")
    assert_equal("", File.read(output))
  end

  def test_containerd_verification_step_uses_the_reported_driver_capability
    ["ci", "publish"].each do |name|
      job_name = name == "ci" ? "build" : "publish"
      step = step_named(workflow(name), job_name, "Verify containerd image store")
      log = File.join(@temporary_directory, "docker.jsonl")
      result, = run_step(step, env: {"DOCKER_MODE" => "driver", "DRIVER_INFO" => "io.containerd.snapshotter.v1", "DOCKER_LOG" => log})
      assert_equal(0, result.exitstatus)
      args = JSON.parse(File.readlines(log).last)
      assert_equal(["info", "--format", "{{json .DriverStatus}}"], args)
      result, = run_step(step, env: {"DOCKER_MODE" => "driver", "DRIVER_INFO" => "legacy overlay", "DOCKER_LOG" => log})
      assert_not_equal(0, result.exitstatus)
    end
  end

  def test_emitted_attestation_verifier_accepts_matching_evidence_and_rejects_wrong_base_digest
    ["ci", "publish"].each do |name|
      job_name = name == "ci" ? "build" : "publish"
      step = job_steps(workflow(name), job_name).find { |candidate| candidate["env"].is_a?(Hash) && candidate["env"].key?("DOCKER_SOCKET") }
      socket_path = "/tmp/cf-#{Process.pid}-#{name}.sock"
      socket = UNIXServer.new(socket_path)
      begin
        valid_file = write_json("attestation-#{name}.json", attestation_documents(BASE_DIGEST))
        curl_log = File.join(@temporary_directory, "curl-#{name}.jsonl")
        shared_env = {
          "DOCKER_SOCKET" => "unix://#{socket_path}", "CURL_MODE" => "attestation",
          "CURL_LOG" => curl_log, "ATTESTATION_FILE" => valid_file,
        }
        expressions = {
          "matrix.base_reference" => "ubuntu:24.04@sha256:#{BASE_DIGEST}",
          "steps.metadata.outputs.tag" => "3.47.3-ubuntu24.04-#{BASE_DIGEST[0, 12]}",
          "env.IMAGE_NAME" => "ghcr.io/mes-systems/containerized-flutter",
        }
        result, stderr, = run_step(step, env: shared_env, expressions: expressions)
        assert_equal(0, result.exitstatus, stderr)
        curl_args = JSON.parse(File.readlines(curl_log).last)
        assert_include(curl_args, "--unix-socket")
        assert_include(curl_args, socket_path)
        assert_include(curl_args, "--get")
        invalid_file = write_json("attestation-wrong-base-#{name}.json", attestation_documents("d" * 64))
        result, = run_step(step, env: shared_env.merge("ATTESTATION_FILE" => invalid_file), expressions: expressions)
        assert_not_equal(0, result.exitstatus)
      ensure
        socket.close
        FileUtils.rm_f(socket_path)
      end
    end
  end

  def test_publish_step_pushes_only_after_synthetic_digest_and_attestations_match
    step = job_steps(workflow("publish"), "publish").find { |candidate| candidate["id"] == "push" }
    provenance_file = write_json("provenance.json", provenance_document(BASE_DIGEST))
    sbom_file = write_json("sbom.json", {"SPDXID" => "SPDXRef-DOCUMENT", "spdxVersion" => "SPDX-2.3"})
    output = File.join(@temporary_directory, "push-output.txt")
    log = File.join(@temporary_directory, "docker-push.jsonl")
    environment = {
      "DOCKER_MODE" => "publish", "DOCKER_LOG" => log, "REGISTRY_DIGEST" => "sha256:#{BUILD_DIGEST}",
      "PROVENANCE_FILE" => provenance_file, "SBOM_FILE" => sbom_file, "GITHUB_OUTPUT" => output,
      "IMAGE_NAME" => "ghcr.io/mes-systems/containerized-flutter",
      "BUILD_TAG" => "3.47.3-ubuntu24.04-#{BASE_DIGEST[0, 12]}-g123456789abc",
      "CANONICAL_TAG" => "3.47.3-ubuntu24.04-#{BASE_DIGEST[0, 12]}",
    }
    expressions = {
      "steps.build.outputs.digest" => "sha256:#{BUILD_DIGEST}",
      "matrix.base_reference" => "ubuntu:24.04@sha256:#{BASE_DIGEST}",
    }
    result, stderr, = run_step(step, env: environment, expressions: expressions)
    assert_equal(0, result.exitstatus, stderr)
    docker_calls = File.readlines(log, chomp: true).map { |line| JSON.parse(line) }
    pushes = docker_calls.select { |args| args.first == "push" }.map(&:last)
    assert_equal(
      ["#{environment.fetch('IMAGE_NAME')}:#{environment.fetch('BUILD_TAG')}",
       "#{environment.fetch('IMAGE_NAME')}:#{environment.fetch('CANONICAL_TAG')}"],
      pushes,
    )
    assert_equal("sha256:#{BUILD_DIGEST}", output_values(output).fetch("digest"))

    negative_log = File.join(@temporary_directory, "docker-push-rejected.jsonl")
    result, stderr, stdout = run_step(
      step,
      env: environment.merge(
        "DOCKER_LOG" => negative_log,
        "PROVENANCE_FILE" => write_json("wrong-provenance.json", provenance_document("d" * 64)),
      ),
      expressions: expressions,
    )
    assert_not_equal(0, result.exitstatus, "stdout=#{stdout.inspect} stderr=#{stderr.inspect} docker=#{File.read(negative_log)}")
    negative_pushes = File.readlines(negative_log, chomp: true).map { |line| JSON.parse(line) }
      .select { |args| args.first == "push" }.map(&:last)
    assert_equal(["#{environment.fetch('IMAGE_NAME')}:#{environment.fetch('BUILD_TAG')}"], negative_pushes)
  end

  def test_image_cleanup_removes_tested_tags_and_fails_if_any_image_remains
    ["ci", "publish"].each do |name|
      job_name = name == "ci" ? "build" : "publish"
      steps = job_steps(workflow(name), job_name)
      build = steps.find { |step| step["uses"].to_s.start_with?("docker/build-push-action@") }
      tags = build.fetch("with").fetch("tags").gsub(/\$\{\{\s*([^}]+?)\s*\}\}/) do
        {
          "steps.metadata.outputs.tag" => "tag", "steps.metadata.outputs.build_tag" => "build-tag",
          "env.IMAGE_NAME" => "ghcr.io/example/image",
        }.fetch(Regexp.last_match(1).strip)
      end.split
      cleanup = step_named(workflow(name), job_name, "Remove tested image")
      expressions = {
        "env.IMAGE_NAME" => "ghcr.io/example/image",
        "steps.metadata.outputs.tag" => "tag", "steps.metadata.outputs.build_tag" => "build-tag",
      }
      state = File.join(@temporary_directory, "images-#{name}.txt")
      File.write(state, tags.join("\n") + "\n")
      environment = {"DOCKER_MODE" => "cleanup", "DOCKER_STATE" => state}
      result, stderr, = run_step(cleanup, env: environment, expressions: expressions)
      assert_equal(0, result.exitstatus, stderr)
      assert_equal("", File.read(state))

      File.write(state, tags.join("\n") + "\n")
      log = File.join(@temporary_directory, "cleanup-#{name}.jsonl")
      result, stderr, stdout = run_step(
        cleanup,
        env: environment.merge("DOCKER_LOG" => log, "DOCKER_FAIL_REMOVE" => tags.first),
        expressions: expressions,
      )
      assert_not_equal(0, result.exitstatus, "stdout=#{stdout.inspect} stderr=#{stderr.inspect} docker=#{File.read(log)}")
      if name == "publish"
        assert_include(stderr + stdout, "test image leaked after cleanup", "docker=#{File.read(log)}")
      end
      assert_include(File.read(state), tags.first)
    end
  end
end

require_relative "workflow_contracts_test_support"
