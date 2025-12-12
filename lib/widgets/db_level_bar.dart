import 'package:flutter/material.dart';

class DbLevelBar extends StatelessWidget {
  final double level; // 0 to 100
  
  const DbLevelBar({
    super.key,
    required this.level,
  });
  
  Color _getColorForLevel(double level) {
    if (level < 30) {
      return Colors.green;
    } else if (level < 60) {
      return Colors.yellow;
    } else if (level < 80) {
      return Colors.orange;
    } else {
      return Colors.red;
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Numeric dB display
        Text(
          '${level.toStringAsFixed(1)} dB',
          style: const TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 20),
        
        // Visual bar indicator
        Container(
          width: double.infinity,
          height: 60,
          decoration: BoxDecoration(
            color: Colors.grey[800],
            borderRadius: BorderRadius.circular(30),
            border: Border.all(
              color: Colors.white24,
              width: 2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(28),
            child: Stack(
              children: [
                // Animated level bar
                AnimatedContainer(
                  duration: const Duration(milliseconds: 100),
                  width: MediaQuery.of(context).size.width * (level / 100),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        _getColorForLevel(level).withOpacity(0.7),
                        _getColorForLevel(level),
                      ],
                    ),
                  ),
                ),
                
                // Grid lines
                Row(
                  children: List.generate(10, (index) {
                    return Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border(
                            right: BorderSide(
                              color: Colors.white.withOpacity(0.1),
                              width: 1,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
        
        const SizedBox(height: 10),
        
        // Scale labels
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: const [
            Text(
              '0',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
            ),
            Text(
              '50',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
            ),
            Text(
              '100',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
