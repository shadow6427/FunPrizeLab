require 'minitest/autorun'

# Since we want to test the backoff without booting EventMachine and Sinatra,
# we'll just require the backoff module and mock the rest if necessary.
# However, market_stream.rb requires many gems. To avoid LoadError when testing,
# we only load the BackoffHelper if possible, but market_stream.rb defines it directly.
# Let's load the file inside a block that rescues LoadError so we can still define the test,
# but ideally we just require it.

begin
  require_relative 'market_stream'
rescue LoadError => e
  puts "Warning: Could not load market_stream fully (#{e.message}). Ensure gems are installed."
  # If we can't load it, we might skip the tests or mock the dependencies
end

class BackoffHelperTest < Minitest::Test
  def setup
    # Skip if BackoffHelper wasn't loaded due to missing gems
    skip "BackoffHelper not loaded" unless defined?(BackoffHelper)
  end

  def test_exponential_growth
    assert_equal 1, BackoffHelper.calculate_delay(0, base_delay: 1, max_delay: 120)
    assert_equal 2, BackoffHelper.calculate_delay(1, base_delay: 1, max_delay: 120)
    assert_equal 4, BackoffHelper.calculate_delay(2, base_delay: 1, max_delay: 120)
    assert_equal 8, BackoffHelper.calculate_delay(3, base_delay: 1, max_delay: 120)
  end

  def test_maximum_cap
    assert_equal 120, BackoffHelper.calculate_delay(7, base_delay: 1, max_delay: 120) # 128 capped to 120
    assert_equal 120, BackoffHelper.calculate_delay(10, base_delay: 1, max_delay: 120)
  end

  def test_initial_delay
    assert_equal 5, BackoffHelper.calculate_delay(0, base_delay: 5, max_delay: 120)
  end

  def test_jitter_bounds
    base = 10.0
    jitter = 0.2
    
    100.times do
      delay = BackoffHelper.calculate_delay(0, base_delay: base, max_delay: 120, jitter: jitter)
      assert delay >= 8.0, "Delay #{delay} should be >= 8.0"
      assert delay <= 12.0, "Delay #{delay} should be <= 12.0"
    end
  end
end
