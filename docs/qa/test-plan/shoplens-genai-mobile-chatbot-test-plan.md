# ShopLens GenAI Mobile Chatbot Test Plan

## 1. Project Name

ShopLens / Cookshop AI

## 2. Feature Under Test

GenAI-powered mobile shopping assistant chatbot and AI product discovery workflows.

## 3. Platforms

* Android
* iOS

## 4. Objective

The objective of this test plan is to validate the ShopLens mobile chatbot and AI product discovery experience across Android and iOS. Testing will ensure that the chatbot understands user shopping intent, returns relevant product recommendations, handles follow-up questions, works with image/live/video scan results, integrates with shopping list workflows, avoids hallucinated product details, handles unsafe prompts properly, and provides a stable mobile user experience.

## 5. Testing Scope

Testing will cover:

* Chatbot launch and mobile UI behavior
* User message entry and chatbot response display
* Product search and recommendation prompts
* Follow-up conversation handling
* AI response relevance validation
* RAG-style product retrieval validation if backend/search data is used
* Hallucination checks
* Prompt injection/security checks
* Image scan, live scan, and video scan context
* Shopping list integration
* API validation if chatbot/product search endpoints are available
* Error handling and fallback messages
* Android/iOS permissions
* App background/foreground behavior
* Network interruption behavior
* Regression testing across Android and iOS

## 6. In Scope

* Android chatbot flow
* iOS chatbot flow
* Product-related questions
* AI-generated product recommendations
* Similar product search from scanned item
* Cheaper alternative product suggestions
* Empty/no-result handling
* Unsupported prompt handling
* Prompt injection testing
* Product result relevance validation
* Shopping list add/update behavior
* Mobile layout validation
* API request/response validation if endpoints are available

## 7. Out of Scope

* Web chatbot testing, unless chatbot is added to web later
* Payment/checkout testing
* Real retailer purchase validation
* Agent handoff, unless implemented
* Admin-only chatbot configuration, unless assigned to QA

## 8. Test Environment

* Android device: Samsung Galaxy S24 or available Android test device
* iOS device: iPhone XR or available iOS test device
* Test build: Dev/Test mobile build
* Test account: QA test user
* Backend: Dev/Test environment
* Tools:

  * Jira or GitHub Issues for defect tracking
  * Postman for API testing
  * JMeter for performance checks if needed
  * Appium or Flutter integration tests for future mobile UI automation
  * Firebase/GCP logs if available

## 9. Entry Criteria

Testing can begin when:

* Android and iOS builds are available
* Chatbot feature is enabled in the test build
* QA test account is available
* Required permissions are configured
* Product search/AI service is connected
* Test data/images are available
* API details are shared if API testing is required

## 10. Exit Criteria

Testing can be completed when:

* All high-priority chatbot test cases are executed
* Critical and high-severity defects are fixed or accepted
* Chatbot returns relevant responses for common shopping prompts
* Chatbot does not expose secrets or hidden instructions
* Chatbot does not invent unsupported product details
* Shopping list integration works correctly
* Android and iOS regression testing is completed
* Known issues and QA sign-off notes are documented

## 11. QA Strategy

ShopLens chatbot testing will be performed using a mobile-first QA strategy. Since GenAI responses can vary, QA will not depend only on exact text matching. Instead, responses will be evaluated using quality criteria such as user intent match, product relevance, factual accuracy, source grounding, no hallucination, safe fallback behavior, and overall usefulness.

Manual testing will be used for AI response quality and usability validation. API testing will be performed using Postman if chatbot/product search endpoints are available. Mobile UI automation can be planned using Appium or Flutter integration tests. Performance checks can be performed using JMeter or API-level load testing.

## 12. Key Risk Areas

* Chatbot may return irrelevant products
* Chatbot may hallucinate price, rating, seller, warranty, or availability
* Chatbot may fail to understand follow-up questions
* Scan result context may not pass correctly to chatbot
* Product search API may return empty or duplicate results
* Prompt injection may expose unsafe/internal information
* Chatbot response time may be slow
* Android and iOS behavior may differ
* Chatbot conversation may not clear after logout
* Network/API failures may cause loading spinner or crash

## 13. Response Quality Criteria

Each chatbot response should be reviewed using the following criteria:

* Did chatbot understand the user intent?
* Are returned products relevant?
* Does response avoid unsupported claims?
* Does chatbot avoid fake price, rating, seller, warranty, or availability?
* Does chatbot handle no-result cases clearly?
* Does chatbot handle unsafe prompts safely?
* Does chatbot maintain context for follow-up questions?
* Does chatbot provide a helpful next step?
* Is response time acceptable?
* Is the UI stable on Android and iOS?

## 14. Defect Reporting Format

Each chatbot defect should include:

* Title
* Platform: Android or iOS
* Build version
* Device model and OS version
* Test prompt used
* Precondition
* Steps to reproduce
* Expected result
* Actual result
* Screenshot/video
* API/log evidence if available
* Severity
* Business impact

## 15. Automation Plan

Current automation approach:

* API automation: Postman/Newman once chatbot API spec is available
* Mobile UI automation: Appium or Flutter integration tests for Android/iOS chatbot flows
* Performance testing: JMeter or API-level performance tests
* CI/CD execution: GitHub Actions can run API regression tests after Postman collection is ready

Playwright will be used only if chatbot is available on web. Since current chatbot functionality is Android/iOS only, Appium or Flutter integration testing is the better choice for UI automation.
