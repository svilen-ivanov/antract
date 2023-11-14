#!/usr/bin/env ruby

require 'net/http'
require 'uri'
require 'thread'

# Configuration
endpoint = 'http://localhost:8082' # Change to your endpoint
thread_count = 50 # Number of threads
requests_per_thread = 60 # Number of requests each thread will make

# Shared resources
mutex = Mutex.new
success_count = 0
failure_count = 0
request_count = 0
$sleep_time = 1
$antract_time = 10
$antract_period = 10

# Define a single request process with keep-alive
def make_request(uri, http)
  sleep_ms = $sleep_time + $sleep_time * Random.rand
  sleep sleep_ms
  response = http.get(uri.request_uri)

  if response.is_a?(Net::HTTPSuccess) && response.body.match?(/Server name: .+/)
    :success
  else
    :failure
  end
end

# Create and start threads
threads = Array.new(thread_count) do
  Thread.new do
    uri = URI(endpoint)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.keep_alive_timeout = 30 # Keep-alive timeout in seconds
      requests_per_thread.times do
        mutex.synchronize do
          request_count += 1
          puts "Performing request #{request_count}"
        end
        result = make_request(uri, http)
        mutex.synchronize do
          if result == :success
            success_count += 1
          else
            failure_count += 1
          end
        end
      end
    end
  end
end

disable_uri = URI("http://localhost:8082/_antract/disable")
enable_uri = URI("http://localhost:8082/_antract/enable")

5.times do
  sleep $antract_period
  puts "Entering antract period"
  response = Net::HTTP.get_response(enable_uri)
  raise response unless response.is_a?(Net::HTTPSuccess) && response.body.match?(/^Pause is enabled/)
  sleep $antract_time
  puts "Exiting antract period"
  response = Net::HTTP.get_response(disable_uri)
  raise response unless response.is_a?(Net::HTTPSuccess) && response.body.match?(/^Pause is disabled/)
end

# Wait for all threads to finish
threads.each(&:join)

# Output statistics
puts "Total Requests: #{thread_count * requests_per_thread}"
puts "Successful Responses: #{success_count}"
puts "Failed Responses: #{failure_count}"
