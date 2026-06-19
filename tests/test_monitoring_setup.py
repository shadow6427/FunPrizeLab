#!/usr/bin/env python3
"""
Test suite for monitoring_setup.py alert rule validation.
Validates that the HighMemoryUsage alert rule has the correct expression.
"""

import sys
import os
import re

# Add the tools directory to the path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'tools'))

from monitoring_setup import RECOMMENDED_ALERT_RULES


def test_high_memory_usage_expression():
    """
    Test that the HighMemoryUsage alert rule has a valid memory ratio expression.
    
    The expression should divide process memory by total machine memory,
    NOT divide by itself (which would always equal 1).
    
    Bug: process_resident_memory_bytes / process_resident_memory_bytes > 0.9
    Fix: process_resident_memory_bytes / machine_memory_bytes > 0.9
    """
    # Find the HighMemoryUsage alert rule
    high_memory_rule = None
    for rule in RECOMMENDED_ALERT_RULES:
        if rule.get('name') == 'HighMemoryUsage':
            high_memory_rule = rule
            break
    
    assert high_memory_rule is not None, "HighMemoryUsage alert rule not found"
    
    expr = high_memory_rule.get('expr')
    assert expr is not None, "HighMemoryUsage rule has no expression"
    
    # Check that the expression does NOT have the self-dividing bug
    # The bug pattern: "process_resident_memory_bytes / process_resident_memory_bytes"
    bug_pattern = r'process_resident_memory_bytes\s*/\s*process_resident_memory_bytes'
    assert not re.search(bug_pattern, expr), \
        f"HighMemoryUsage expression has self-dividing bug: {expr}"
    
    # Check that it divides by machine_memory_bytes
    assert 'machine_memory_bytes' in expr, \
        f"HighMemoryUsage expression should divide by machine_memory_bytes: {expr}"
    
    # Check that the expression includes a ratio threshold
    assert '> 0.9' in expr or '> 0.8' in expr or '> 0.7' in expr or '> 0.5' in expr, \
        f"HighMemoryUsage expression should have a threshold: {expr}"
    
    print("✓ HighMemoryUsage alert rule expression is correct")
    print(f"  Expression: {expr}")
    return True


def test_all_alert_rules_have_expressions():
    """Test that all alert rules have valid expressions."""
    for rule in RECOMMENDED_ALERT_RULES:
        assert rule.get('expr'), f"Alert rule {rule.get('name')} missing expression"
        assert rule.get('name'), "Alert rule missing name"
        assert rule.get('duration'), f"Alert rule {rule.get('name')} missing duration"
    
    print(f"✓ All {len(RECOMMENDED_ALERT_RULES)} alert rules have required fields")
    return True


def test_high_memory_usage_rule_details():
    """Test that HighMemoryUsage rule has correct metadata."""
    high_memory_rule = None
    for rule in RECOMMENDED_ALERT_RULES:
        if rule.get('name') == 'HighMemoryUsage':
            high_memory_rule = rule
            break
    
    assert high_memory_rule is not None
    assert high_memory_rule.get('severity') == 'warning'
    assert high_memory_rule.get('duration') == '10m'
    assert 'High memory usage' in high_memory_rule.get('summary', '')
    
    print("✓ HighMemoryUsage rule has correct metadata")
    return True


if __name__ == '__main__':
    print("Running monitoring_setup.py tests...")
    print()
    
    try:
        test_high_memory_usage_expression()
        test_all_alert_rules_have_expressions()
        test_high_memory_usage_rule_details()
        
        print()
        print("=" * 60)
        print("All tests passed!")
        print("=" * 60)
        sys.exit(0)
    except AssertionError as e:
        print(f"\n❌ Test failed: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ Unexpected error: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)
