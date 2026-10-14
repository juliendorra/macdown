require 'yaml'

workflow = YAML.load_file('.github/workflows/ci.yml')
jobs = workflow.fetch('jobs')
native = jobs.fetch('macos')
condition = native.fetch('if').gsub(/\s/, '')
expected = "${{ github.event_name == 'workflow_dispatch' && inputs.apple_build }}".gsub(/\s/, '')
abort 'Mac job must require explicit workflow dispatch and apple_build' unless condition == expected
abort 'Mac job must depend on cheap checks' unless native.fetch('needs') == 'portable'
abort 'Mac job must have a bounded timeout' unless native.fetch('timeout-minutes') <= 20
commands = native.fetch('steps').map { |step| step['run'] }.compact
abort 'Mac pipeline must run once, reusing the portable prerequisite' unless commands == [
  'caffeinate -d -i -u python3 Scripts/test_pipeline.py full --portable-checked'
]
checkout = jobs.fetch('portable').fetch('steps').find { |step| step['uses']&.start_with?('actions/checkout@') }
abort 'History scan needs full history and submodules' unless checkout.fetch('with') == {
  'fetch-depth' => 0, 'submodules' => 'recursive'
}
puts 'Workflow economy and test-prerequisite checks passed.'
