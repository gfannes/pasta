&!:pier

Software to determine a minimal set of Sequences of interdependent Courses. These Sequences are the input for creating an actual Schedule.

# Rationale
- Produce a Schedule with a minimal amount of Lessons filled-in. Unspecified Lessons translate in more freedom later when a complete and specific Schedule is produced.
- Lessons for Sections that are given to Classes belonging to different Groups must be present in the Schedule.
- When the Schedule mentions at least one Lesson for an Hour for a Group, it must be completed with Lessons for all Classes in that Group.
- Courses that are too large for a single Section must be split, preferably grouping Classes belonging to the same Group together.
- Additional Constraints might be present for a Course: a specific classroom or teacher might be required.

# WBS
## Input
- [x] Info on Classes, Groups, Courses and Constraints from a single `.csv` file
- [x] Maximum Section capacity
- [ ] An optional Schedule that must be used as starting point
## Output
- [x] Terminal print-out
- [ ] A list of Schedules in `.csv` format, with a score
## Processing
- [x] Determing sizes for data structures
- [x] Create data structures
- [x] Load data from input
- [/] Process recursively
	- [x] Single-shot fitting: the first slot that fits is take, not backtracking
	- [ ] Try all available slots
- [ ] Convert Courses into Sections
	- For now, a Course is treated as a Section
- Sort solutions by score
- Write-out solutions with score

# Terms

Schedule
: A grid Lessons with Hours in the rows and Classes in the columns

Class
: Group of students that have the same Courses

Group
: Set of Classes that follow common courses

Course
: A theme of lessons with a fixed number of hours per week

Section
: A specific offering of a Course limited by the maximum capacity

Lesson
: One of potentially many lesson hours for a given Section

Hour
: One of 32 hours where a Lesson can be teached

Constraint
: A limitation on the scheduling of a Course or Section
