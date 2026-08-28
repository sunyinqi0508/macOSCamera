import CoreGraphics

struct PreviewLayout {
    static func aspectFitRect(containerSize: CGSize, aspectRatio: CGFloat) -> CGRect {
        guard containerSize.width > 0,
              containerSize.height > 0,
              aspectRatio > 0 else {
            return .zero
        }

        let containerRatio = containerSize.width / containerSize.height

        if containerRatio > aspectRatio {
            let fittedHeight = containerSize.height
            let fittedWidth = fittedHeight * aspectRatio
            let originX = (containerSize.width - fittedWidth) / 2
            return CGRect(x: originX, y: 0, width: fittedWidth, height: fittedHeight)
        }

        let fittedWidth = containerSize.width
        let fittedHeight = fittedWidth / aspectRatio
        let originY = (containerSize.height - fittedHeight) / 2
        return CGRect(x: 0, y: originY, width: fittedWidth, height: fittedHeight)
    }
}
